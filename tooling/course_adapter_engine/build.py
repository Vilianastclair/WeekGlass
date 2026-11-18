"""Build the pinned JVM parser for both hosts with Python 3.9+ and JDK 17+."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

from prepare import ROOT, prepare
from audit import audit

K = "2.2.21"
RUNTIME = [f"org.jetbrains.kotlin:kotlin-stdlib:{K}", "com.google.code.gson:gson:2.11.0",
           "org.jsoup:jsoup:1.15.4","com.github.doyaaaaaken:kotlin-csv-jvm:1.10.0",
           "org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.8.0"]
ANNOTATIONS = "org.jetbrains:annotations:13.0"
COMPILER = [f"org.jetbrains.kotlin:{a}:{K}" for a in ("kotlin-compiler-embeddable","kotlin-script-runtime","kotlin-daemon-embeddable")] + ["org.jetbrains.kotlin:kotlin-reflect:1.6.10",ANNOTATIONS]
# Build-time cache only; the product never downloads code.
def resolve(coord):
    group, artifact, version = coord.split(":")
    filename = f"{artifact}-{version}.jar"
    portable = Path(os.environ.get("WEEKGLASS_TOOLCHAIN_HOME","C:/WeekGlassToolchain"))
    for gradle in (os.environ.get("GRADLE_USER_HOME"), portable/"gradle-cache",Path.home()/".gradle"):
        if gradle:
            jars = sorted((Path(gradle)/"caches/modules-2/files-2.1"/group/artifact/version).glob("*/"+filename))
            if jars: return jars[0]
    cache = Path(os.environ.get("COURSE_ADAPTER_MAVEN_CACHE",Path.home()/".cache/weekglass-courseadapter/maven")) / group.replace(".","/") / artifact / version
    cache.mkdir(parents=True,exist_ok=True)
    path = cache/filename
    if not path.exists():
        url = f"https://repo1.maven.org/maven2/{group.replace('.','/')}/{artifact}/{version}/{filename}"
        with tempfile.NamedTemporaryFile(dir=cache,delete=False) as tmp:
            try:
                with urllib.request.urlopen(url,timeout=90) as src: shutil.copyfileobj(src,tmp)
            except Exception as err:
                raise RuntimeError(f"Cannot resolve {coord} at {url}") from err
        os.replace(tmp.name,path)
    return path

def jdk():
    if os.environ.get("JAVA_HOME"): return Path(os.environ["JAVA_HOME"])/"bin"
    if shutil.which("javac"): return Path(shutil.which("javac")).parent
    return Path(os.environ.get("WEEKGLASS_TOOLCHAIN_HOME","C:/WeekGlassToolchain"))/"jdk/current/bin"

def invoke(args, cwd):
    # javac/Kotlin argument files avoid the Windows process command length limit.
    path = cwd/"args"
    path.write_text("\n".join('"'+str(a).replace('\\','/').replace('"','\\"')+'"' for a in args[1:]),encoding='utf8')
    subprocess.run([str(args[0]),"@"+str(path)],cwd=cwd,check=True)

def cli_manifest(runtime):
    # Manifest continuation lines start with one space; stay within the byte limit.
    fields=["Manifest-Version: 1.0","Main-Class: org.weekglass.courseadapter.Main",
            "Class-Path: "+" ".join("lib/"+p.name for p in runtime)]
    lines=[]
    for field in fields:
        while len(field)>70:
            lines.append(field[:70])
            field=" "+field[70:]
        lines.append(field)
    return ("\r\n".join(lines)+"\r\n\r\n").encode("ascii")

def build(no_compile=False, dist=ROOT/"dist"):
    dist = Path(dist).resolve()
    work = ROOT/"build"
    work.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=work) as folder:
        temp = Path(folder)
        data = prepare(temp/"src")
        raw = json.dumps(data,ensure_ascii=False,indent=2)+"\n"
        registry = ROOT/"registry.json"
        if not registry.exists() or registry.read_text(encoding="utf8") != raw:
            registry.write_text(raw,encoding="utf8")
        if no_compile: return
        cp = [resolve(c) for c in RUNTIME]
        ann = resolve(ANNOTATIONS)
        compiler = cp + [resolve(c) for c in COMPILER]
        classes = temp/"classes"; classes.mkdir()
        sources = sorted((temp/"src").rglob("*.kt")) + sorted((ROOT/"src").glob("*.kt"))
        java = sorted((temp/"src").rglob("*.java"))
        javabin = jdk()
        jvm = str(javabin/"java")
        suffix = os.pathsep
        invoke([jvm, "-Xmx1600m", "-cp",suffix.join(map(str,compiler)), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
               "-Xjsr305=ignore","-Xnullability-annotations=@javax.annotation:ignore","-no-stdlib","-no-reflect","-language-version","1.9","-nowarn","-jvm-target","17",
               "-classpath",suffix.join(map(str,cp+[ann])),"-d",str(classes),*sources,*java],temp)
        invoke([str(javabin/"javac"),"--release","17","-encoding","UTF-8","-proc:none","-cp",suffix.join(map(str,[classes]+cp+[ann])),"-d",str(classes),*java],temp)
        audit(classes)
        dist.mkdir(parents=True,exist_ok=True)
        lib=dist/"lib"; lib.mkdir(exist_ok=True)
        for f in cp: shutil.copyfile(f,lib/f.name)
        with tempfile.TemporaryDirectory(dir=dist) as stage:
            with zipfile.ZipFile(Path(stage)/"engine.jar","w",compression=zipfile.ZIP_DEFLATED) as jar:
                def put(name,b):
                    entry=zipfile.ZipInfo(name,(2025,1,1,0,0,0)); entry.compress_type=zipfile.ZIP_DEFLATED
                    jar.writestr(entry,b)
                put("META-INF/MANIFEST.MF",cli_manifest(cp))
                for f in sorted(classes.rglob("*")):
                    if f.is_file(): put(f.relative_to(classes).as_posix(),f.read_bytes())
                put("courseadapter/registry.json",raw.encode())
                put("META-INF/LICENSE.CourseAdapter",(ROOT/"LICENSE.CourseAdapter").read_bytes())
                for notice in sorted((ROOT/"licenses").glob("*.txt")):
                    put("courseadapter/licenses/"+notice.name,notice.read_bytes())
            shutil.copytree(ROOT/"licenses",dist/"licenses",dirs_exist_ok=True)
            os.replace(Path(stage)/"engine.jar",dist/"engine.jar")
        print(f"Built {len(data['adapters'])} registered modes: {dist/'engine.jar'}")

if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--registry-only",action="store_true")
    parser.add_argument("--dist",type=Path,default=ROOT/"dist",help="output directory for the engine, libraries and licenses")
    options=parser.parse_args()
    build(options.registry_only, options.dist)

