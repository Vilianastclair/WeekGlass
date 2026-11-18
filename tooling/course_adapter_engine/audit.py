"""Inspect constant-pool member references in the compiled upstream code (JVMS 4.4)."""
import struct

def members(data):
    if data[:4]!=b"\xca\xfe\xba\xbe": raise ValueError("Invalid class")
    count=struct.unpack_from(">H", data,8)[0]; pool=[None]*count; offset=10
    i=1
    while i<count:
        tag=data[offset]; offset+=1
        if tag==1:
            length=struct.unpack_from(">H",data,offset)[0]
            pool[i]=data[offset+2:offset+2+length].decode("utf8",errors="replace")
            offset+=2+length
        elif tag in {7,8,16,19,20}:
            pool[i]=(tag,*struct.unpack_from(">H",data,offset)); offset+=2
        elif tag in {9,10,11,12,17,18}:
            pool[i]=(tag,*struct.unpack_from(">HH",data,offset)); offset+=4
        elif tag in {3,4}: offset+=4
        elif tag in {5,6}: offset+=8; i+=1
        elif tag==15: offset+=3
        else: raise ValueError(f"Unknown JVM constant pool tag {tag}")
        i+=1
    for item in pool:
        if isinstance(item,tuple) and item[0] in {9,10,11}:
            _,owner,member=item
            _,name,desc=pool[member]
            yield (pool[pool[owner][1]],pool[name],pool[desc])

def audit(root):
    for f in root.rglob("*.class"):
        path=f.relative_to(root).as_posix()
        # These are our two entry points and the generated, statically typed dispatch table.
        if path.startswith("org/weekglass/courseadapter/"): continue
        for owner,name,desc in members(f.read_bytes()):
            forbidden=(owner.startswith(("java/io/","java/net/","java/nio/file/","java/lang/reflect/","javax/script/","kotlin/io/")) and owner!="java/io/IOException"
                       or owner in {"java/lang/Runtime","java/lang/ProcessBuilder","java/lang/ClassLoader"}
                       or owner=="java/lang/Class" and name not in {"getName","getSimpleName","getCanonicalName","desiredAssertionStatus"}
                       or owner=="java/lang/System" and name not in {"arraycopy","currentTimeMillis","nanoTime"}
                       or owner=="org/jsoup/Jsoup" and not (name=="parse" and desc in {"(Ljava/lang/String;)Lorg/jsoup/nodes/Document;","(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;"})
                       or owner.startswith(("org/jsoup/helper/Http","org/jsoup/Connection"))
                       or owner.endswith("/Element") and name=="connection")
            if forbidden: raise ValueError(f"{path}: unexpected capability {owner}.{name}{desc}")

