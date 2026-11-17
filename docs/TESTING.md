# 测试与验证范围

## 单元测试

先运行 `bash Tools/build-lame.sh`，再运行 `swift test`。

105 项测试包括：

- 音频处理与文件保护：15 项
- 处理路由：17 项
- 编码格式及回读：16 项
- 波形包络：12 项
- 自动命名与并发防覆盖：10 项
- 菜单栏 / 保存反馈策略：14 项
- 外放协议与误调保护：21 项

音频测试使用合成 PCM。输出文件只写到测试临时目录，不写入用户 Downloads，不启动音频捕获，也不改变真实扬声器音量。

## 可选 GUI 自测

```sh
bash build.sh
mkdir -p work/qa-light work/qa-dark
open -n -W dist/声流.app --args --snapshot-directory "$PWD/work/qa-light" --exercise-ui
open -n -W dist/声流.app --args --snapshot-directory "$PWD/work/qa-dark" --dark --exercise-ui
```

这会打开应用自己的测试窗口，产生 PNG 和 JSON 结果，然后退出。请勿在重要录音或其他交互操作期间运行 GUI 自测。

自测使用不持久化的预览模型：

- 录音入口被明确禁用。
- 外放使用模拟状态，不写入硬件。
- 合成波形带有预览标记。
- MP3 编码测试在指定 `work/` 目录写入合成文件。
- Finder 定位使用注入回调，不弹出用户文件夹。
- 菜单选择通过应用自己的原生菜单动作检查，并不等同于跨应用自动化。

每个 `*-tests.json` 中的检查值应为 `true`；`bundled-mp3-test.json` 的 `passed` 和 `syntheticOnly` 应为 `true`。不要将生成的录音、JSON、截图缓存或日志提交到仓库。

## 必须人工验收的范围

- 用户授权后的真实应用 / 系统音频捕获。
- 麦克风始终不被采集，空闲时没有音频捕获。
- 实际格式、听感、长时录音和文件完成后的 Finder 定位。
- 真实设备的音量读写、热插拔、休眠和设备切换。
- 显示器 / 转接器的 DDC 兼容性。
- 其他系统版本和硬件架构。

没有真实硬件写入或实际录音验证时，请明确说明，不用模拟测试代替端到端兼容性承诺。
