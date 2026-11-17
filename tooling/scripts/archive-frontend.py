"""Export design assets only; no app archive or release packages."""
from pathlib import Path
from html import escape
from urllib.parse import quote
import argparse
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SPEC = '''# 流光玻璃

不需要的都删掉，保持精简。内容占据主体，光影提供触感，文字保持清晰。

## 材质

玻璃像湖面倒影：透明底层之上，局部色光缓慢交融。文字、外轮廓与布局保持稳定。类别色以透光的反射层呈现，避免厚重实色和刺眼霓虹绿。

面板自顶部向下受光，连续细亮边围合轮廓，细反光集中于上缘；以柔和外投影呈现悬浮感。侧栏与主面板之间保留空气，时间栏与内容共享连续底层。

## 尺寸与排版

| 项目 | 数值 |
| --- | --- |
| 圆角矩形 | 统一绝对半径 12；薄形状由高度自然限制 |
| 轮廓 | 1 |
| 主面板外投影 | 向下偏移 7，模糊 20 |
| 外边距、面板间距 | 12 |
| 窄侧栏 | 44 |
| 字体 | Noto Sans SC 可变字体 |
| 内容标题 | 14 / 480，行高 1.15 |
| 紧凑标题 | 12.5 |
| 次要时间 | 10.5，等宽数字 |

标题与次要文字成组对齐；文字密度由卡片尺寸与字号统一决定，不因名称长短而整块消失。过薄卡片保持空白玻璃块；够一行时显示标题，预留可辨认标题宽度后仍能放下完整时间才并排显示时间。较高卡片分两行。极窄卡片无法显示可辨认标题时留空，避免只有省略号；其余长标题正常省略。悬停浮层避开原内容，补全名称、时间和备注。

## 色彩

月光冰蓝、雾紫水晶、玫瑰石英、香槟琥珀、冰川青、曜石银，各有浅深两套。

内容类别色为雾蓝、鸢尾紫、冰青、暮杏、蔷薇、琥珀、月灰，与全局皮肤独立。浅色日程减少冰白混色，以更鲜明的分类色参与流动透光；透明底层、文字、轮廓和全局面板保持原样，月灰仍为中性色。daylightFlowTint 对应浅色日程，flowTint 保留深色和原材质用途。完整色值见同目录 design-tokens.json，编码为 #AARRGGBB。

## 动态

色光默认强度 72%，范围 0–125%。背景、面板和卡片属于同一湖面光影体系。指针与触摸只扰动局部倒影，点击形成自然消退的涟漪，不以追踪白色光斑代替流动。

低频色光在数秒内可感知平移与形变，反射带经过透明底层；文字和轮廓保持稳定。材质片段是 4 秒、20fps 的真实逐帧渲染，循环处回到起点，仅作视觉样张，不代表设备性能或应用运行时的循环方式。

手机流光用两股连续色光代替桌面的噪声纹理采样，保留透明度、分类色、局部扰动和涟漪。手机画面与桌面流光片段分别标识。

跟手画面连续；目标影子以克制阻尼追随落点，原位置淡影保持稳定。短暂反馈自动消退，以细进度条表达剩余时间。减少动态效果时保持稳定材质，隐藏时停止绘制。

版本提示复用玻璃对话框，仅保留版本信息、后台更新说明及两个操作；主操作实色强调，跳过作为次操作。窄屏与大字下可自然换行。

## 账号页面

沿用月光冰蓝浅深色、连续亮边、顶部受光及悬浮投影，品牌使用同一透明 W 标记。账号网页默认浅色，不随系统自动变暗；右上角的外观选择可切换深浅并记住选择，登录、账号与管理后台共用。网页主要矩形使用 22 像素圆角，桌面和手机原生组件保持 12 逻辑像素。网页中文字体采用本机 Noto Sans SC、苹方或微软雅黑回退，避免额外下载整套字体。设置首页以流光「云服务」入口显示服务状态，订阅按钮收在云服务内。桌面云快捷图标固定在侧栏设置上方，手机固定在底栏设置旁；都可隐藏，新安装默认显示。三个入口共用轻量虹彩反射层，背景静止或减少动态时停下，文字不随色光变化。账号管理留在网页。账号与官网样式见 Web 目录；登录预览仅为本地视觉样张，不会登录或提交账号。
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--previews', type=Path, required=True)
    args = parser.parse_args()
    destination = args.destination.resolve(strict=True)
    if destination.name != '前端':
        raise ValueError('Destination must be the explicitly selected 前端 asset directory.')
    tokens = json.loads((args.previews / 'design-tokens.json').read_text(encoding='utf-8'))
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+\+\d+)\s*$',
                      (ROOT / 'apps/client/pubspec.yaml').read_text(encoding='utf-8'), re.M)
    if not match:
        raise ValueError('Client version is missing.')
    tokens['version'] = match.group(1)
    version = tokens['version'].split('+')[0]
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Invalid asset version.')
    bundle = destination / f'WeekGlass-前端设计-v{version}'
    if bundle.is_symlink() or (bundle.exists() and bundle.resolve().parent != destination):
        raise ValueError('Asset bundle must remain directly inside the destination.')
    bundle.mkdir(exist_ok=True)
    records = []

    def put(relative, data):
        target = bundle / relative
        if not target.resolve().is_relative_to(bundle.resolve()):
            raise ValueError(relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        records.append({'path': relative, 'bytes': len(data)})

    def copy(source, relative):
        put(relative, source.read_bytes())

    put('01设计规范/视觉规范.md', SPEC.encode('utf-8'))
    put('01设计规范/design-tokens.json', (json.dumps(tokens, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))
    for path in sorted((ROOT / 'apps/client/assets').rglob('*')):
        if path.is_file():
            copy(path, '03视觉资产/' + path.relative_to(ROOT / 'apps/client/assets').as_posix())
    copy(ROOT / 'apps/client/windows/runner/resources/app_icon.ico', '03视觉资产/brand/app_icon.ico')

    design = ROOT / 'packages/design_system'
    copy(design / 'pubspec.yaml', '04玻璃组件/Flutter/pubspec.yaml')
    for folder, pattern in (('lib', '*.dart'), ('shaders', '*.frag')):
        for path in sorted((design / folder).rglob(pattern)):
            copy(path, '04玻璃组件/Flutter/' + path.relative_to(design).as_posix())
    copy(ROOT / 'apps/client/lib/features/mobile/mobile_glass_backdrop.dart',
         '04玻璃组件/Flutter/examples/mobile_glass_backdrop.dart')

    skins = ('moonstone', 'amethyst', 'rose_quartz', 'champagne', 'glacier', 'graphite')
    surfaces = ('gallery-desktop', 'event-details', 'weekly-editor', 'hover-{}-left',
                'flow-settings', 'course-import-preview', 'android-day', 'android-week')
    names = [f'{skin}-{mode}.png' for skin in skins for mode in ('light', 'dark')]
    names.extend((surface.format(mode) if '{}' in surface else f'{surface}-{mode}') + '.png'
                 for surface in surfaces for mode in ('light', 'dark'))
    for name in names:
        copy(args.previews / name, '02界面样张/' + name)
    for mode in ('light', 'dark'):
        name = f'android-details-compact-{mode}.png'
        copy(args.previews / 'android-interaction' / name, '02界面样张/' + name)
        for phase in ('start', 'flow'):
            frame = args.previews / 'android-interaction' / f'android-lake-{phase}-{mode}.png'
            if frame.is_file():
                copy(frame, '02界面样张/流光片段/' + frame.name)
    short_sample = args.previews / 'short-event-empty-and-hover.png'
    if short_sample.is_file():
        copy(short_sample, '02界面样张/' + short_sample.name)
    for mode in ('light', 'dark'):
        film = args.previews / f'lake-{mode}.webp'
        if film.is_file():
            copy(film, '02界面样张/流光片段/' + film.name)
    for path in sorted((args.previews / 'auth').glob('*.png')):
        if path.name.startswith(('login-', 'expired-', 'callback-', 'handoff-')):
            copy(path, '02界面样张/账号/' + path.name)

    sys.path.insert(0, str(ROOT / 'server/runtime'))
    for folder in ('commercial-settings', 'mobile-time-zoom', 'commercial-website', 'startup-update', 'event-color', 'web-account-theme', 'admin-console'):
        for path in sorted((ROOT / 'design-reference/previews' / folder).rglob('*')):
            if path.is_file() and path.suffix.lower() in ('.png', '.jpg', '.webp'):
                copy(path, '02界面样张/' + folder + '/' + path.relative_to(ROOT / 'design-reference/previews' / folder).as_posix())

    from weekglass_server.console_style import CSS as CONSOLE_STYLE
    from weekglass_server.web_theme import THEME_STYLE, THEME_SCRIPT
    from weekglass_server.auth_pages import page
    account_preview = page('design-preview-only', portal=True)
    account_styles = re.findall(r'<style>(.*?)</style>', account_preview, flags=re.S)
    put('04玻璃组件/Web/account.css', '\n'.join(account_styles).encode('utf-8'))
    put('04玻璃组件/Web/console.css', (THEME_STYLE + CONSOLE_STYLE).encode('utf-8'))
    put('04玻璃组件/Web/theme.js', THEME_SCRIPT.encode('utf-8'))
    copy(ROOT / 'infra/weekglass/public-site/assets/weekglass.css', '04玻璃组件/Web/website.css')
    account_preview = re.sub(r'<style>.*?</style>', '', account_preview, flags=re.S)
    account_preview = account_preview.replace('</head>',
        '<link rel="stylesheet" href="04玻璃组件/Web/account.css"></head>')
    account_preview = re.sub(r'src="data:image/png;base64,[^"]+"',
        'src="03视觉资产/brand/mark.png"', account_preview)
    account_preview = re.sub(r'<input type="hidden"[^>]+>', '', account_preview)
    account_preview = account_preview.replace('method="post" action="/v1/auth/authorize"', '')
    account_preview = account_preview.replace('</script>',
        "document.querySelectorAll('form').forEach(f=>f.addEventListener('submit',e=>e.preventDefault()));</script>")
    put('登录预览.html', account_preview.encode('utf-8'))

    # Material source and specimen only; no prototype project or copied fonts.
    prototype = ROOT / 'design-reference/prototypes/liquid-lake'
    app = (prototype / 'src/App.jsx').read_text(encoding='utf-8')
    app = re.sub(r'      <details className="comparison">.*?</details>\s*', '', app, flags=re.S)
    app = app.replace('/assets/mark.png', '03视觉资产/brand/mark.png')
    app = app.replace('已确认方案 · 原生应用已接入', '清透底层与稳定轮廓')
    app = app.replace('清透底层 · 稳定轮廓', '清透底层与稳定轮廓')
    app = app.replace('min="0.25"', 'min="0"')
    css = (prototype / 'src/styles.css').read_text(encoding='utf-8')
    css = css.replace('/assets/NotoSansSC-Variable.ttf', '../../03视觉资产/fonts/NotoSansSC-Variable.ttf')
    css = css.replace('/assets/atmosphere.png', '../../03视觉资产/brand/atmosphere.png')
    # Single light direction on the specimen surround; Lake stays unchanged.
    css += '\n.stage{background:linear-gradient(180deg,#ffffff6b,#edf2ff33 42%,#d9e5ff1f);box-shadow:0 7px 20px #30446926,inset 0 1px 0 #ffffff8c}.dark .stage{background:linear-gradient(180deg,#cedfff33,#9eaddd24 42%,#9eaddd1a);box-shadow:0 7px 20px #03060b66,inset 0 1px 0 #ffffff29}.controls button{border-radius:12px}\n'
    put('04玻璃组件/Web/App.jsx', app.encode('utf-8'))
    copy(prototype / 'src/Lake.jsx', '04玻璃组件/Web/Lake.jsx')
    put('04玻璃组件/Web/styles.css', css.encode('utf-8'))
    licenses = [(prototype / 'node_modules' / package / 'LICENSE').read_text(encoding='utf-8')
                for package in ('react', 'react-dom', 'scheduler')]
    if len(set(licenses)) != 1:
        raise ValueError('Review changed preview dependency licenses before exporting.')
    put('04玻璃组件/Web/LICENSE.txt',
        ('React / React DOM / Scheduler\n\n' + licenses[0]).encode('utf-8'))
    event_tokens = json.dumps(tokens["events"], ensure_ascii=False)
    entry = app + '\nimport {createRoot} from "react-dom/client"; const archivedEventTokens=' + event_tokens + '; createRoot(document.getElementById("root")).render(<App eventTokens={archivedEventTokens}/>);'
    esbuild = prototype / 'node_modules/@esbuild/win32-x64/esbuild.exe'
    compiled = subprocess.run([str(esbuild), '--bundle', '--format=iife', '--minify',
                               '--loader=jsx', '--define:process.env.NODE_ENV="production"',
                               '--sourcefile=' + str(prototype / 'src/design-preview.jsx')],
                              input=entry.encode('utf-8'), capture_output=True, check=True,
                              cwd=prototype / 'src').stdout.decode('utf-8')
    html = ('<!doctype html><html lang="zh-CN"><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>流光玻璃材质</title><link rel="stylesheet" href="04玻璃组件/Web/styles.css">'
            '<div id="root"></div><script>' + compiled.replace('</script', '<\\/script') + '</script></html>')
    put('流光预览.html', html.encode('utf-8'))

    cards = []
    for record in records:
        if record['path'].startswith('02界面样张/'):
            url = quote(record['path'], safe='/')
            label = escape(Path(record['path']).stem)
            cards.append(f'<figure><a href="{url}"><img loading="lazy" src="{url}" alt="{label}"></a><figcaption>{label}</figcaption></figure>')
    gallery = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>流光玻璃设计资产</title><style>body{margin:0;padding:32px;background:#e9eff7;color:#26344d;font:14px/1.7 "Microsoft YaHei",sans-serif}main{max-width:1200px;margin:auto}h1{font-weight:500;font-size:28px}nav{display:flex;flex-wrap:wrap;gap:20px;margin:24px 0}a{color:#566594}.gallery{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:20px}figure{margin:0;padding:12px;border-radius:12px;background:#ffffff66;border:1px solid white;box-shadow:0 7px 20px #2a3f6414}img{width:100%;height:auto;border-radius:12px}figcaption{font-size:11px;padding-top:6px}</style><main><h1>流光玻璃</h1><nav><a href="01设计规范/视觉规范.md">视觉规范</a><a href="01设计规范/design-tokens.json">配色与尺寸</a><a href="03视觉资产/">字体与图形</a><a href="04玻璃组件/">玻璃组件</a><a href="流光预览.html">流光预览</a></nav><div class="gallery">'''
    gallery = gallery.replace('</nav>', '<a href="登录预览.html">登录预览</a></nav>')
    put('打开设计总览.html', (gallery + ''.join(cards) + '</div></main></html>').encode('utf-8'))
    # Inventory goes to the pruning caller, not into the user's asset folder.
    print(json.dumps({'bundle': str(bundle), 'files': records}, ensure_ascii=True))


if __name__ == '__main__':
    main()
