#import "AccountBridge.h"
#import <xpc/xpc.h>

void WGRegisterAccountBroker(id<FlutterBinaryMessenger> messenger) {
    FlutterMethodChannel *channel=[FlutterMethodChannel methodChannelWithName:@"weekglass/macos_account" binaryMessenger:messenger];
    [channel setMethodCallHandler:^(FlutterMethodCall *call,FlutterResult result){
        if(![call.method isEqual:@"account"] || ![call.arguments isKindOfClass:NSString.class]){result(FlutterMethodNotImplemented);return;}
        NSData *data=[call.arguments dataUsingEncoding:NSUTF8StringEncoding];
        NSString *idn=NSBundle.mainBundle.bundleIdentifier;
        NSString *leaf=[NSBundle.mainBundle objectForInfoDictionaryKey:@"WGAccountSigningLeaf"];
        NSCharacterSet *notHex=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFabcdef"] invertedSet];
        if(leaf.length!=40 || [leaf rangeOfCharacterFromSet:notHex].location!=NSNotFound || !idn || data.length>32768){
            result([FlutterError errorWithCode:@"account_configuration" message:@"当前构建未配置账号服务。" details:nil]);return;
        }
        NSString *service=[idn stringByAppendingString:@".account"];
        NSString *rule=[NSString stringWithFormat:@"identifier \"%@\" and certificate leaf = H\"%@\"",service,leaf];
        dispatch_queue_t queue=dispatch_queue_create("weekglass.account.call",DISPATCH_QUEUE_SERIAL);
        __block xpc_connection_t discovery=xpc_connection_create(service.UTF8String,queue);
        __block xpc_connection_t connection=NULL;
        __block BOOL completed=NO;
        void (^finish)(NSString*)=^(NSString *reply){
            if(completed)return;completed=YES;
            if(connection){xpc_connection_cancel(connection);connection=NULL;}
            if(discovery){xpc_connection_cancel(discovery);discovery=NULL;}
            dispatch_async(dispatch_get_main_queue(),^{result(reply ?: [FlutterError errorWithCode:@"account_unavailable" message:@"安全账号服务暂时不可用。" details:nil]);});
        };
        if(!discovery || xpc_connection_set_peer_code_signing_requirement(discovery,rule.UTF8String)){finish(nil);return;}
        xpc_connection_set_event_handler(discovery,^(xpc_object_t e){if(xpc_get_type(e)==XPC_TYPE_ERROR && !completed)finish(nil);});
        xpc_connection_resume(discovery);
        xpc_object_t hello=xpc_dictionary_create(NULL,NULL,0);xpc_dictionary_set_bool(hello,"hello",true);
        xpc_connection_send_message_with_reply(discovery,hello,queue,^(xpc_object_t signedReply){
            if(completed)return;
            xpc_object_t ep=xpc_get_type(signedReply)==XPC_TYPE_DICTIONARY?xpc_dictionary_get_value(signedReply,"endpoint"):NULL;
            if(!ep || xpc_get_type(ep)!=XPC_TYPE_ENDPOINT){finish(nil);return;}
            connection=xpc_connection_create_from_endpoint(ep);
            if(!connection || xpc_connection_set_peer_code_signing_requirement(connection,rule.UTF8String)){finish(nil);return;}
            xpc_connection_set_target_queue(connection,queue);
            xpc_connection_set_event_handler(connection,^(xpc_object_t e){if(xpc_get_type(e)==XPC_TYPE_ERROR && !completed)finish(nil);});
            xpc_connection_resume(connection);
            xpc_object_t request=xpc_dictionary_create(NULL,NULL,0); xpc_dictionary_set_data(request,"request",data.bytes,data.length);
            xpc_connection_send_message_with_reply(connection,request,queue,^(xpc_object_t response){
                if(completed)return;
                size_t length=0;
                const void *bytes=xpc_get_type(response)==XPC_TYPE_DICTIONARY?xpc_dictionary_get_data(response,"response",&length):NULL;
                NSString *out=bytes&&length<=65536?[[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding]:nil;
                finish(out);
            });
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),queue,^{if(!completed)finish(nil);});
    }];
}
