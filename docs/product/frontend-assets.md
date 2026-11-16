# 导出前端设计资产

在配有设计样张和材质预览源码的 Windows 工作区中，用 PowerShell 7 执行：

```powershell
.\tooling\scripts\sync-frontend-assets.ps1 -Destination $assetDirectory -Previews $previewDirectory
```

`$assetDirectory` 是专门存放 WeekGlass 当前设计资产、名为「前端」的现有目录。同步成功后，脚本会清除该目录内旧版本的 WeekGlass 设计包；选择目录前请确认它的用途。

`$previewDirectory` 提供同一版的 `design-tokens.json` 和合成日程样张。脚本还需要工作区中的 `design-reference/prototypes/liquid-lake` 材质预览源码，以及该目录的 Node 依赖（React、React DOM、Scheduler 和 Windows x64 esbuild）。这些设计输入不随公开的客户端和服务端源码下载，也不影响产品构建。设计工作区准备好后，打开导出目录中的「打开设计总览.html」即可浏览样张、样式与材质演示。
