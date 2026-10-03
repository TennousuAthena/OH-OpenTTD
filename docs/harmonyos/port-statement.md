# HarmonyOS 移植声明

本版本由 TennousuAthena 将 OpenTTD 移植到 HarmonyOS，保留 OpenTTD 的原版玩法、图形素材和存档格式。

## 移植作者与开源仓库

- 移植作者：[TennousuAthena](https://github.com/TennousuAthena)
- 移植源码：[OH-OpenTTD](https://github.com/TennousuAthena/OH-OpenTTD)
- 上游项目：[OpenTTD](https://github.com/OpenTTD/OpenTTD)

## HarmonyOS 适配

本移植基于 OpenTTD 15.3 正式版，上游基线为 `14ec60f248547d4d062a1160f0fc26d742319888`。

当前鸿蒙版版本号为 **15.3-harmonyos.1**。联机兼容版本保持 **15.3**，可连接相同版本的原版服务器；服务器要求的 NewGRF 等内容仍需匹配。

本移植提供 HarmonyOS 原生窗口、画面呈现、鼠标与触摸输入、音频播放及应用生命周期适配，并使用 OpenTTD 官方原版图标。

鼠标进入活动的游戏画面时，自动隐藏系统指针，保留游戏中的工具光标；鼠标离开画面、窗口失去焦点或应用进入后台时恢复系统指针。

## 开源许可与制作人员

OpenTTD 及本移植遵循 GNU GPL v2 许可。完整许可正文可从“帮助和手册”的许可按钮查看。

原始设计由 Chris Sawyer 创作，原始图形由 Simon Foster 创作。OpenTTD 的程序、素材及第三方组件保留各自的贡献者署名和许可；完整制作人员名单保留在游戏的“关于 OpenTTD”窗口中。

## 技术资料

- [移植与性能记录](./port-notes.md)
- [HarmonyOS 移植指南](./port-guide.md)
