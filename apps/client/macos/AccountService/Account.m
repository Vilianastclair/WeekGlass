#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <xpc/xpc.h>

// A newly enrolled WeekGlass session belongs to this service. The host receives
// an opaque session ID and online, short-lived access grants, never a stored
// refresh token. All requests for these grants go to the enrolled origin.

static NSArray *identityKeys(void) {
    return @[@"server_id", @"account_id", @"device_id", @"dataset_id", @"sync_epoch"];
}
static NSDictionary *failure(NSString *code, NSInteger status) {
    return @{@"error":code, @"status":@(status)};
}
static NSDictionary *item(void) {
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService:[[NSBundle mainBundle] bundleIdentifier],
             (__bridge id)kSecAttrAccount:@"WeekGlass account v1",
             (__bridge id)kSecUseDataProtectionKeychain:@NO,
             (__bridge id)kSecAttrSynchronizable:@NO};
}
static NSMutableDictionary *stored(OSStatus *status) {
    NSMutableDictionary *q=[item() mutableCopy];
    q[(__bridge id)kSecReturnData]=@YES; q[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
    CFTypeRef out=NULL; *status=SecItemCopyMatching((__bridge CFDictionaryRef)q,&out);
    NSData *data=CFBridgingRelease(out);
    if(*status==errSecItemNotFound) { *status=errSecSuccess; return [NSMutableDictionary dictionary]; }
    if(*status || !data)return nil;
    id result=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if(![result isKindOfClass:[NSMutableDictionary class]]) { *status=errSecDecode; return nil; }
    return result;
}
static OSStatus save(NSMutableDictionary *state) {
    if(!state.count) {
        OSStatus s=SecItemDelete((__bridge CFDictionaryRef)item()); return s==errSecItemNotFound ? errSecSuccess:s;
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if(!data)return errSecParam;
    NSDictionary *value=@{(__bridge id)kSecValueData:data};
    OSStatus s=SecItemUpdate((__bridge CFDictionaryRef)item(),(__bridge CFDictionaryRef)value);
    if(s!=errSecItemNotFound)return s;
    NSMutableDictionary *q=[item() mutableCopy]; [q addEntriesFromDictionary:value];
    q[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleWhenUnlocked;
    return SecItemAdd((__bridge CFDictionaryRef)q,NULL);
}
static BOOL string(id v) {return [v isKindOfClass:NSString.class] && [v length]>0;}
static BOOL validOrigin(NSString *value) {
    if(!string(value))return NO;
    NSURLComponents *u=[NSURLComponents componentsWithString:value];
    return [u.scheme isEqual:@"https"] && u.host.length && !u.user && !u.password && !u.query &&
        !u.fragment && !u.path.length && [u.URL.absoluteString isEqual:value];
}
static BOOL validGrant(NSDictionary *g) {
    if(![g[@"token_type"] isEqual:@"Bearer"] || !string(g[@"access_token"]) || !string(g[@"refresh_token"]) ||
       [g[@"access_token"] length]<32 || [g[@"refresh_token"] length]<32)return NO;
    for(NSString *key in identityKeys())if(!string(g[key]) || ![[NSUUID alloc] initWithUUIDString:g[key]])return NO;
    return YES;
}
@interface GrantDelegate:NSObject<NSURLSessionTaskDelegate>
@end
@implementation GrantDelegate
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request completionHandler:(void(^)(NSURLRequest*))completion { completion(nil); }
#ifdef WG_TEST_SERVER_CA
// The isolated integration bundle trusts its ephemeral loopback certificate
// chain only for the test server. No production asset contains this branch.
- (void)URLSession:(NSURLSession*)session didReceiveChallenge:(NSURLAuthenticationChallenge*)challenge completionHandler:(void(^)(NSURLSessionAuthChallengeDisposition,NSURLCredential*))completion {
    if (![challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust] ||
        ![challenge.protectionSpace.host isEqual:@"127.0.0.1"] || challenge.protectionSpace.port!=18766) {
        completion(NSURLSessionAuthChallengePerformDefaultHandling,nil);return;
    }
    SecTrustRef trust=challenge.protectionSpace.serverTrust;
    NSData *der=[[NSData alloc] initWithBase64EncodedString:@WG_TEST_SERVER_CA options:0];
    SecCertificateRef cert=SecCertificateCreateWithData(NULL,(__bridge CFDataRef)der);
    if(!cert||!trust){if(cert)CFRelease(cert);completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge,nil);return;}
    OSStatus s=SecTrustSetAnchorCertificates(trust,(__bridge CFArrayRef)@[(__bridge id)cert]);
    CFRelease(cert);
    if(!s && !SecTrustSetAnchorCertificatesOnly(trust,true) && SecTrustEvaluateWithError(trust,NULL))
        completion(NSURLSessionAuthChallengeUseCredential,[NSURLCredential credentialForTrust:trust]);
    else completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge,nil);
}
#endif
@end

static NSString *escaped(NSString *v) {
    NSCharacterSet *unreserved=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [v stringByAddingPercentEncodingWithAllowedCharacters:unreserved];
}
static NSDictionary *post(NSString *origin,BOOL revoke,NSDictionary *body) {
    NSURL *url=[NSURL URLWithString:[origin stringByAppendingString:(revoke?@"/v1/auth/revoke":@"/v1/auth/token")]];
    if(!url)return failure(@"invalid_origin",400);
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];request.HTTPMethod=@"POST";
    if(revoke) {
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    } else {
        NSMutableArray *pairs=[NSMutableArray array];
        for(NSString *k in body) { if(!string(body[k]))return failure(@"invalid_grant",400);
            [pairs addObject:[NSString stringWithFormat:@"%@=%@",escaped(k),escaped(body[k])]]; }
        [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody=[[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    }
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage=nil;config.URLCache=nil;config.URLCredentialStorage=nil;config.timeoutIntervalForRequest=25;config.timeoutIntervalForResource=35;
    NSURLSession *session=[NSURLSession sessionWithConfiguration:config delegate:[GrantDelegate new] delegateQueue:nil];
    dispatch_semaphore_t sem=dispatch_semaphore_create(0); __block NSDictionary *out;
    NSURLSessionDataTask *task=[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *err) {
        NSInteger status=[(NSHTTPURLResponse*)response statusCode];
        id value=(!err && data && data.length<=65536) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        if(err || ![value isKindOfClass:NSDictionary.class])out=failure(@"account_transport",status ?: 503);
        else if(status<200 || status>=300)out=failure([value[@"code"] isKindOfClass:NSString.class]?value[@"code"]:@"account_request",status);
        else out=value;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    if(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,39*NSEC_PER_SEC))!=0) {
        [session invalidateAndCancel];return failure(@"account_timeout",503);
    }
    [session finishTasksAndInvalidate];return out;
}
static NSMutableDictionary *publicState(NSDictionary *rec,NSString *shortGrant) {
    NSMutableDictionary *v=[NSMutableDictionary dictionary];
    for(NSString *key in identityKeys())v[key]=rec[key];
    v[@"origin"]=rec[@"origin"];v[@"token_type"]=@"Bearer";v[@"refresh_token"]=rec[@"handle"];
    if(shortGrant)v[@"access_token"]=shortGrant;
    v[@"merge_approved"]=rec[@"merge_approved"] ?: @NO;
    v[@"sleep_schedule_approved"]=rec[@"sleep_schedule_approved"] ?: @NO;
    return v;
}
static NSDictionary *operate(NSDictionary *message) {
    OSStatus status; NSMutableDictionary *all=stored(&status);
    if(!all)return failure(@"keychain",status);
    NSString *op=message[@"op"], *handle=message[@"handle"];
    NSMutableDictionary *active=all[@"active"], *pending=all[@"pending"];
    NSMutableDictionary *rec=string(handle)&&[pending[@"handle"] isEqual:handle] ? pending :
        string(handle)&&[active[@"handle"] isEqual:handle] ? active:nil;
    if([op isEqual:@"restore"])return active?@{@"value":publicState(active,nil)}:@{};
    if([op isEqual:@"clear"]){[all removeAllObjects];status=save(all);return status?failure(@"keychain",status):@{};}
    if([op isEqual:@"commit"]) {
        if(!rec)return failure(@"unknown_session",401);
        rec[@"merge_approved"]=@([message[@"merge"] isEqual:@YES]);rec[@"sleep_schedule_approved"]=@([message[@"sleep"] isEqual:@YES]);
        all[@"active"]=rec;[all removeObjectForKey:@"pending"];
        status=save(all);return status?failure(@"keychain",status):@{};
    }
    if([op isEqual:@"revoke"]) {
        if(!rec || !validOrigin(rec[@"origin"]))return failure(@"unknown_session",401);
        return post(rec[@"origin"],YES,@{@"refresh_token":rec[@"refresh"],@"device_id":rec[@"device_id"]});
    }
    BOOL enroll=[op isEqual:@"authorize"];
    if(!enroll && ![op isEqual:@"renew"])return failure(@"unknown_operation",400);
    NSString *origin=enroll?message[@"origin"]:rec[@"origin"];
    if(!validOrigin(origin))return failure(@"invalid_origin",400);
    NSDictionary *body;
    if(enroll) {
        for(NSString *k in @[@"device_id",@"code",@"code_verifier",@"redirect_uri",@"server_id"])if(!string(message[k]))return failure(@"invalid_grant",400);
        NSURLComponents *u=[NSURLComponents componentsWithString:message[@"redirect_uri"]];
        if(![u.scheme isEqual:@"http"] || ![u.host isEqual:@"127.0.0.1"] || ![u.path isEqual:@"/oauth/callback"] || u.port.integerValue<1024 || u.port.integerValue>65535 || u.user || u.password || u.query || u.fragment)return failure(@"invalid_callback",400);
        body=@{@"grant_type":@"authorization_code",@"client_id":@"weekglass-native",@"device_id":message[@"device_id"],@"code":message[@"code"],@"code_verifier":message[@"code_verifier"],@"redirect_uri":message[@"redirect_uri"]};
    }else {
        if(!rec)return failure(@"unknown_session",401);
        body=@{@"grant_type":@"refresh_token",@"client_id":@"weekglass-native",@"device_id":rec[@"device_id"],@"refresh_token":rec[@"refresh"]};
    }
    NSDictionary *grant=post(origin,NO,body);
    if(grant[@"error"])return grant;
    if(!validGrant(grant))return failure(@"invalid_response",502);
    if(enroll && (![grant[@"device_id"] isEqual:message[@"device_id"]] || ![grant[@"server_id"] isEqual:message[@"server_id"]]))return failure(@"changed_identity",401);
    if(!enroll)for(NSString *k in identityKeys())if(![grant[k] isEqual:rec[k]])return failure(@"changed_identity",401);
    if(enroll){rec=[NSMutableDictionary dictionary];rec[@"handle"]=NSUUID.UUID.UUIDString;rec[@"origin"]=origin;all[@"pending"]=rec;}
    for(NSString *k in identityKeys())rec[k]=grant[k];
    rec[@"refresh"]=grant[@"refresh_token"];status=save(all);
    if(status)return failure(@"keychain",status);
    return @{@"value":publicState(rec,grant[@"access_token"])};
}

// The keychain and form exchange are serialized across app connections so that
// two overlapping refreshes cannot race a rotated credential.
static dispatch_queue_t queue;
static const char *callerRule="identifier \"" WG_HOST_ID "\" and certificate leaf = H\"" WG_LEAF "\"";
static void serve(xpc_connection_t c) {
    if(xpc_connection_set_peer_code_signing_requirement(c,callerRule)){xpc_connection_cancel(c);return;}
    xpc_connection_set_event_handler(c,^(xpc_object_t m){
        if(xpc_get_type(m)!=XPC_TYPE_DICTIONARY)return;
        xpc_object_t reply=xpc_dictionary_create_reply(m);if(!reply)return;
        xpc_transaction_begin();
        dispatch_async(queue,^{@autoreleasepool {
            size_t n=0; const void* bytes=xpc_dictionary_get_data(m,"request",&n);
            id input=bytes&&n<=32768 ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:n] options:0 error:nil]:nil;
            NSDictionary *out=[input isKindOfClass:NSDictionary.class]?operate(input):failure(@"invalid_message",400);
            NSData *data=[NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
            xpc_dictionary_set_data(reply,"response",data.bytes,data.length);xpc_connection_send_message(c,reply);
            xpc_transaction_end();
        }});
    });xpc_connection_resume(c);
}
// Authenticate the service's initial reply before the host sends a PKCE
// verifier. Its anonymous endpoint is a capability for this service instance.
static void acceptHost(xpc_connection_t c) {
    if(xpc_connection_set_peer_code_signing_requirement(c,callerRule)){xpc_connection_cancel(c);return;}
    __block xpc_connection_t listener=NULL;
    xpc_connection_set_event_handler(c,^(xpc_object_t m){
        if(xpc_get_type(m)==XPC_TYPE_ERROR){if(listener)xpc_connection_cancel(listener);listener=NULL;return;}
        if(xpc_get_type(m)!=XPC_TYPE_DICTIONARY || !xpc_dictionary_get_bool(m,"hello") || listener)return;
        xpc_object_t r=xpc_dictionary_create_reply(m);if(!r)return;
        listener=xpc_connection_create(NULL,NULL);
        xpc_connection_set_event_handler(listener,^(xpc_object_t peer){ if(xpc_get_type(peer)==XPC_TYPE_CONNECTION) serve(peer); });
        xpc_connection_resume(listener);xpc_endpoint_t ep=xpc_endpoint_create(listener);
        xpc_dictionary_set_value(r,"endpoint",ep);xpc_connection_send_message(c,r);
    });xpc_connection_resume(c);
}
int main(void) {
#ifdef WG_TEST_SERVER_CA
    SecKeychainSetUserInteractionAllowed(false);
#endif
    queue=dispatch_queue_create("com.viliana.weekglass.account",DISPATCH_QUEUE_SERIAL);
    xpc_main(acceptHost);
}
