# 原生皮肤开发

皮肤包使用原生场景 v2，由 App 渲染布局、数据绑定、材质、交互和效果。包内可以包含图片、字体、循环视频和 Metal 源码。普通用户在播放页或全屏设置中导入 ZIP，再从列表选择皮肤。

本文描述开发中的 v2 接口。JSON v1 不再接受。

## 包结构

ZIP 根目录包含 `manifest.json`。场景可直接写在 manifest 的 `scene` 中，也可写成包内 JSON 相对路径；`scenes.window` 和 `scenes.fullscreen` 可以提供各自布局。两个模式的选择与参数独立保存。

```json
{
  "formatVersion": 2,
  "hostAPIVersion": 2,
  "version": "1.0.0",
  "descriptor": {"id": "example.reading", "name": "阅读"},
  "requires": ["scene@2", "theme@1"],
  "scene": {
    "root": {
      "type": "text",
      "text": "=track.title",
      "fontSize": 32,
      "color": "=theme.appForeground.primary"
    }
  }
}
```

`author` 填写作者署名，最多 24 个字符。`sidebar` 在设置的皮肤卡片右侧加一条竖排边栏：`label` 写在顶端，作为简短标识，例如 `beta`、`实验` 或 `限定`，最多 12 个字符；`showsAuthor` 为 true 时，把 `author` 以 `-by 作者` 的形式写在底端，`showsAuthorPrefix` 为 false 时只写作者名；`visible` 为 false 时隐藏边栏并保留其余写法。省略 `sidebar` 的卡片不带边栏。

```json
"author": "kmgccc",
"sidebar": {"label": "beta", "showsAuthor": true}
```

`preview` 指定皮肤卡片上的正方形预览图，可写包内路径，也可写成 `{"image": "preview.png", "dark": "preview-dark.png", "themed": true}`，深色外观使用 `dark`。图片为 png、jpg 或 heic，边长建议 512 像素，不少于 256 像素。未写 `preview` 时，App 按场景的构图生成预览：在固定视口和样例数据下取一次布局，只画封面、歌词、标题与可视化几块主体，配色跟随当前主题。逐字运动、镜头、着色器与粒子不参与，因此以动效为主的皮肤更适合自带预览图。

预览图与设置界面同处一行，遵循以下规范：

- **主题模板。** 推荐 `themed: true`：只用纯红 `#FF0000`、纯绿 `#00FF00`、纯蓝 `#0000FF` 作画，卡片分别换成当前主题的强调色、前景色与带强调色调的中性色。三色都与卡片形成对比：深色卡片上取浅色，浅色卡片上取深色。三色可调不透明度，也可相互叠压，过渡按混合比例换色。背景留透明，透出卡片底色。
- **最多三色。** 非模板图片同样以三种颜色为限，色相克制，大面积用中性色，强调色只点在一处。
- **意象。** 用一两个简洁图形点出皮肤的主题与气质，例如一方封面、几道光、一阵上涌的字形。避免截图、文字、按钮与图标，也避免繁复的细节。
- **构图。** 主体居中偏稳，四周留出约八分之一边长的空白；卡片边长约 150 点，细于 2% 边长的线条会消失。

[JSON Schema](skin-package-v2.schema.json)用于编辑器补全和结构检查。表达式、组件与能力的最终校验由 App 的 `skin.check` 完成。

包只能引用自身目录内的本地资源。路径使用相对路径，不能包含上级目录、绝对路径或链接。包中最多 4096 个条目、展开后最多 512 MiB，单个资源最多 128 MiB；JSON 最多 4 MiB，字体最多 16 个。ZIP 使用普通存储或 Deflate 压缩。

## 布局与节点

`layer` 自由定位子节点；`row`、`column`、`stack`、`grid` 组合布局；`scroll` 提供纵向滚动，`scrollTo` 绑定一个 repeat 序号时，该行变化后滚到中央。`switch` 按第一个满足 `when` 的分支选择，未命中时用 `default`。`repeat` 的 `items` 绑定数组，`template` 中使用 `item`、`index` 与 `count`。绑定动态数组时，`limit` 给出最多绘制的行数，展开后的节点按它计入 2000 个节点的上限；未写时按 1024 行计。直接放在 `scroll` 中的纵向 repeat 只构建可见的行，按最多 48 行计入。`"layout": "free"` 的 repeat 像 `layer` 一样按每格自己的 frame x/y 定位，适合逐词排版；它直接放在带 `camera` 的图层里时，每格各按自己的 `depth` 跟随镜头。

`frame` 包含 `x/y/width/height/size`、尺寸上下限、`aspectRatio`、`padding`、`fill` 和 `anchor`。数值是逻辑点；尺寸还接受 `50%`、`10vw`、`10vh`、`vmin` 与 `vmax`。百分比相对父容器，视口单位相对实际宿主。

内容节点包括 `text`、`lyricLine`、`symbol`、`image`、`artwork`、`video`、`shape` 与 `gradient`。未写 `color` 的文字、符号和形状使用主题的主要前景色。

任一节点写上 `"adaptive": true`，宿主就读取它所在位置下方的背景明暗，为整棵子树选择可读的前景：未写颜色的文字、符号和形状随之变色，系统材质与配色方案随之翻转，`control.miniPlayer` 等原生控件改用相应的前景与玻璃。节点表达式可读 `self.backdrop`（`light` 或 `dark`）、`self.foreground` 与 `self.secondaryForeground`。判断以封面铺满视口为背景估计，并计入 `background.host` 与 `background.dimming` 的压暗；只在节点移动、封面或压暗变化时重算。文字可设 `font`、`fontSize`、`weight`、`design`（rounded、serif、monospaced）、`italic`、`tracking`、`lineSpacing`、`lineLimit`、`alignment` 与 `minScale`。`gradient` 的 `mode` 为 linear、radial、elliptical、angular 或 light；`stops` 写成 `{"color": …, "at": 0.4}` 的数组，未写时 `colors` 均匀分布；径向渐变以 `start` 为中心，`radius` 为相对节点长边的半径，在非正方形的框里会被短边截断；椭圆渐变随框拉伸，`radius` 为 0.5 时恰好在框边缘收尽，适合宽幅光晕。light 是一点光源，亮度随距离按平方反比衰减，颜色取第一个色标，`radius` 为光核占半个框的比例（默认 0.08）；光随框拉伸并在框边缘柔和收尽，扁长的框便是一道横向光芒；渐变带抖动，长距离的过渡保持平滑。形状支持矩形、圆、椭圆、胶囊和单位正方形坐标内的路径。路径命令使用大写 M/L/C/Q/H/V/Z，坐标为绝对值。

`component` 通过 `component` 名称调用宿主组件，`props` 传参数。`lyrics` 是 `lyrics.native` 的简写。原生歌词（含 `lyrics.panel`）每个可实现布局最多一份，不能放入 repeat；自绘歌词没有这个限制。

作者模板放在场景的 `components` 字典或包内 `components/*.json`，通过 `use` 的 `name` 和 `props` 调用。模板不能循环引用。

编译错误给出文件与 JSON 路径；拼错的节点、属性、组件、操作或事件名会附上最接近的正确名称。

## 宿主组件

内置五套皮肤的每个部件都可以单独调用，尺寸由节点的 `frame` 决定。

| 分组 | 组件 |
| --- | --- |
| 歌词 | `lyrics.native`、`lyrics.panel` |
| 封面 | `artwork.basic`、`artwork.classicFrame`、`artwork.appleStyle`、`artwork.rotatingDisc`、`artwork.coverGradientBlur` |
| 磁带 | `cassette.shell`、`cassette.label`、`cassette.reels`、`cassette.waveform`、`cassette.kmgLook`、`cassette.overlay` |
| 背景 | `background.host`、`background.unifiedMesh`、`background.amllMesh`、`background.coverGradientBlur`、`background.art`、`background.artworkBlur`、`background.dimming`、`transition.bokeh` |
| 可视化 | `visualizer.capsuleSpectrum`、`visualizer.pillSpectrum`、`visualizer.led`、`visualizer.waveform`、`visualizer.progressSpectrum` |
| 控制 | `control.miniPlayer`、`control.leadingCapsule`、`control.volumeCapsule`、`control.transport`、`control.playPause`、`control.skip`、`control.previous`、`control.next`、`control.progress`、`control.volume`、`control.expandableVolume`、`control.playbackMode`、`control.like`、`control.dislike`、`control.outputDevice`、`control.queue`、`control.lyricsToggle`、`control.fullscreen`、`control.settings`、`control.quickPanel`、`control.actionButton`、`control.glassButton`、`control.glassTriplePill`、`control.progressLine`、`control.actionStack`、`control.playbackModeStack` |
| 文字 | `text.trackInfo`、`text.trackDescription`、`text.marquee` |
| 面板 | `panel.queue`、`panel.quickAppearance`、`panel.trackDetail`、`sheet.trackEdit`、`sheet.externalInfo`、`sheet.settings`、`menu.trackContext`、`menu.player` |
| 行为 | `behavior.autoHide`、`behavior.lyricsEndAutoHide`、`behavior.scrollVolume`、`behavior.pointerOcclusion`、`behavior.windowDrag` |

窗口里的播放条由 App 固定提供，皮肤不能替换或移除；`control.miniPlayer`、`control.leadingCapsule` 与 `control.volumeCapsule` 只在全屏显示，写在窗口场景里不会出现。

`text.trackDescription` 在节点的 `frame` 内显示完整歌曲介绍，内容超出时可滚动；`props` 支持 `fontSize`、`color` 和 `alignment`（`leading` 或 `center`）。本地歌曲按歌曲、专辑、首位艺人的顺序取第一段非空介绍；没有介绍或播放外部来源时留空。切歌时滚动位置重置。

```json
{
  "type": "component",
  "component": "text.trackDescription",
  "frame": {"width": 320, "height": 240},
  "props": {"fontSize": 14, "alignment": "leading"}
}
```

`control.miniPlayer` 默认与全屏播放条等长，并在节点 `frame` 内居中。`props` 可调：`width` 为 1 倍尺寸下的总长度，`align` 为 leading、center 或 trailing；`showsLeading`、`showsVolume`、`showsTrackInfo`、`showsTransport`、`showsPlaybackMode`、`showsProgress` 与 `showsLyricsButton` 控制各部分显隐。隐去进度后，播放条按内容收紧。

`background.host` 绘制宿主在该皮肤后方的背景：用户开启艺术背景且皮肤不自带背景时显示艺术背景，否则显示 `preset` 指定内置皮肤的背景，并沿用全屏压暗。`background.art` 直接调用艺术背景。

`control.leadingCapsule` 与 `control.volumeCapsule` 须在同一布局中成对出现。行为组件包住 `children`：`behavior.autoHide` 在指针静止后隐藏内容，`delay` 为 0 时常显，`behavior.scrollVolume` 让滚轮调节音量，`behavior.windowDrag` 让拖动内容即可移动窗口。

`menu.player` 给 `children` 附上迷你播放器的完整菜单，分为 `info`（音乐资料）、`track`（喜欢与不喜欢、添加到播放列表、查看详情、编辑歌曲信息、查看艺人与专辑、从资料库删除）、`external`（外部播放覆盖信息）、`order`（四种播放顺序）、`view`（播放队列、歌词、快速外观与全屏）和 `output`（输出设备）。`include` 选出其中几段；`trigger` 为 `click` 时单击即弹出，适合“更多”按钮，默认为右键。`menu.trackContext` 是同一菜单，默认只含前三段。全屏中不显示查看艺人与专辑。

`control.playPause`、`control.previous` 与 `control.next` 是迷你播放器中带动画的按钮，可分开摆放：`size` 为点击区域边长（默认 26），`symbolSize` 为图标大小，`color` 与 `disabledColor` 为可用与禁用时的颜色，`blendMode` 为混合方式。`control.transport` 把三者排成一行，另有 `spacing` 与 `navSymbolSize`。按钮动画读取 MotionKit token，所在节点写上 `motion` 即可调节。`control.playbackMode` 是播放顺序滑块胶囊，可调 `scale`、`iconSize`、`color` 与 `expanded`。

`visualizer.led` 是迷你播放器的 LED 频谱：`count` 为灯数（1 至 64），`levels` 为亮度级数（2 至 16），`color` 为灯色，`tone` 为 `light`、`standard`、`bright` 或 `miniPlayer`，`scheme` 为 `dark` 或 `light`，`bright` 提亮灯色，`direction` 为 `leftToRight` 时从左侧点亮（默认自中间向两侧），另有 `dotSize`、`spacing`、`tint`、`pill`、`statusLight`、`paddingX` 与 `paddingY`。`visualizer.capsuleSpectrum` 的 `count` 为胶囊数，`color` 为主色，`artworkColors` 为 false 时不取封面色，`darkForeground` 改用深色，`scale` 缩放，`paused` 为 `dots` 时暂停后只留圆点。

`control.progressLine` 是一条细进度线：指针移上时轨道与已播部分一同加粗，下方左右两端以迷你播放器的数字过渡显示已播时间与总时长；拖动时预览，松手跳转。`height` 与 `hoverHeight` 为平时与悬停时的粗细（默认 2.5 与 6），`hitHeight` 为响应指针的高度，`color`、`trackOpacity`、`timeSize` 与 `timeGap` 调整颜色与时间。节点 `frame` 的顶部放进度线，下方留出时间的高度。

`control.actionStack` 与 `control.playbackModeStack` 是向上弹出的按钮列，节点 `frame` 只写底部按钮的大小，弹出的按钮在它上方逐个出现。`control.actionStack` 的底部按钮为全屏或退出全屏，指针移上后依次弹出音量、快速外观与歌词；指针停在喇叭上时，音量条从左侧展开，可拖动或滚动调节，单击喇叭静音。`control.playbackModeStack` 的底部按钮为当前播放顺序，弹出其余三种；展开时再单击当前顺序即打开播放队列。两者弹出用 MotionKit 的 control 弹簧，`bounce` 为弹性（默认 0.22），`duration` 为弹出时长秒数（默认取 control 时长），`stagger` 为相邻按钮的间隔秒数（默认 0.045）；指针在整列与展开的音量条范围内移动时保持展开，离开 `grace` 秒（默认 0.35）后收起，拖动音量期间不收起；指针移到另一列时，前一列立即收起。另可调 `size`、`symbolSize`、`spacing` 与 `color`，`control.actionStack` 还有 `volumeWidth` 与 `volumeHeight`。

`control.like` 与 `control.dislike` 切换当前曲目的喜欢与不喜欢；`symbol` 指定轮廓图标，选中时用其 `.fill` 版本，另有 `fontSize`、`color` 与 `activeColor`。`control.outputDevice` 显示当前输出设备的图标与名称，单击列出可选设备，`showsName` 为 false 时只显示图标。

`builtin.<皮肤>.artwork`、`.background` 与 `.overlay` 按内置皮肤自身的绘制调用整层，皮肤为 `coverLed`、`appleStyle`、`rotatingCover`、`kmgccc.cassette` 与 `fullscreen.coverGradientBlur`。默认在节点 `frame` 内绘制；`props.layout` 为 `host` 时铺满视口，按宿主的画布、封面列和封面缩放排布，与内置皮肤位置一致。`template.classicLED`、`template.appleStyle`、`template.rotatingCover`、`template.cassette` 与 `template.coverGradientBlur` 以 `background.host`、宿主排布的图层、原生歌词和迷你播放器组成完整场景，可直接作为起点。

`lyrics.native` 的 `props` 接受原生歌词设置，例如 `fontSize`、`fontWeight`、`textColor`、`alignPosition`、`showTranslation`、`hidePassedLines`、`surface`、`translationLanguage`、`romanizationLanguage`、`obscenity`，以及 `palette` 与 `motion` 记录。渲染精度、缓存与时间偏移由 App 管理。

几项常用写法：

- `highlight`：`smooth` 为扫光，`discrete` 为逐字亮起，`line` 只按行切换。扫光宽度用 `wordFadeWidth`，余晖用 `preserveCompletedHighlight`，强调与辉光用 `enableEmphasis`、`enableGlow` 与 `glowRadiusScale`，行间弹性用 `enableSpring`、`springDuration` 与 `springBounce`。
- `hierarchy`：未唱与远处的行如何退后。`opacity` 降低当前色的透明度，`brightness` 让颜色朝背景过渡、保持不透明。`activeColor` 为当前色，`inactiveLevel` 与 `translationLevel` 为 0 到 1 的层级，`hierarchyBase` 指定过渡的终点色，默认按当前色的明暗取黑或白。显式写出的 `palette` 优先。
- `userSettings`：留给用户在设置中调整的歌词选项，可写 `all`（默认）、`none`，或 `font`、`highlight`、`spring` 的数组。未列出的分组按 App 默认值起算，再应用皮肤的设定；设置页会注明哪款皮肤使用自己的设定。

这些属性都可以绑定 `params`，配合 `isUserVisible` 的参数就能出现在快速面板里。

完全自绘时不放 `lyrics.native`，改用 `lyrics` 数据域：`lyrics.lines` 是全文与逐词时间，`lyrics.current`、`lyrics.lineProgress`、`lyrics.wordIndex` 与 `lyrics.wordProgress` 逐帧更新。当前行与原生歌词一样提前进入，换行不落后于演唱；首个词晚于行起点的行（例如与上一行共用起点的行）在首个词开唱时才成为当前行。`lyricLine` 节点显示相对当前行第 `index` 行的文字，`mode` 为 `translation` 或 `romanization` 时显示译文或罗马音；写上 `highlightColor` 后，已唱部分自左向右染色，按逐词时间推进，适合单行显示；`highlightStyle` 为 `word` 时改为逐词由 `color` 过渡到 `highlightColor`，换行也准确。

## 数据与表达式

以 `=` 开头的字符串是表达式，其他值是常量。支持算术、比较、布尔、条件表达式、成员与下标访问、记录 `{x: 1, y: a + b}`，以及固定函数表。需要循环或成段算法时，写成包内脚本。

manifest 顶层的 `let` 为反复出现的表达式命名，例如 `"let": {"heroX": "=viewport.width / 2 + state.line.x"}`，任何表达式里写 `let.heroX` 即可使用。命名表达式在使用处展开，因此能读到当地的 `props`、`item`、`index` 与 `glyph`；它们可以互相引用，引用成环时检查报错。每处展开的 `follow()` 各有一份弹簧。

包内 `scripts/*.js` 按文件名顺序载入同一个 JavaScriptCore 环境，每个文件最多 1 MiB。全局函数在表达式里以 `script("函数名", 参数…)` 调用；参数与结果是数、文字、布尔、列表与记录，颜色以十六进制文字传入。脚本里的 `host` 提供 `host.measureText(文字, 字号, 字重, 字体)`、`host.lineHeight(字体, 字重, 字号)` 与 `host.wordStarts(文字)`（系统分词给出的各词起点，以 UTF-16 计）；脚本没有网络、文件与定时器。`script()` 只在参数变化时运行，适合写在 `watch` 里，换行时算一次并存入 state。脚本出错时返回 null 并记一次日志，写成 `script(…) ?? state.line` 便保留旧值。`skin.check` 列出脚本中的函数，并核对 `script()` 引用的名称。

自定义排版可读取 `track.description`（完整介绍）、`track.descriptionSource`（`track`、`album`、`artist` 或空字符串）和 `track.descriptionAttribution`（继承时的来源说明）。它们与 `text.trackDescription` 使用相同的继承规则；没有可用介绍时均为空字符串。可将文字节点放入 `scroll` 以阅读较长内容。

常用数据域：

| 域 | 内容 |
| --- | --- |
| `track`、`artwork` | 跨来源曲目信息、来源、封面身份、色板及动态封面可用状态 |
| `playback`、`clock` | 控制可用性、播放状态、音量、播放顺序、音频与歌词时钟 |
| `lyrics` | 全文、逐词时间、翻译、罗马音、背景人声、当前行与间奏 |
| `theme` | ThemeStore 的语义角色、分析结果与控件前景策略 |
| `audio` | 共享 PCM、FFT、RMS、峰值、LED、频段与可用状态 |
| `viewport`、`host` | 实际视口、显示比例、宿主、可访问性与可见性 |
| `like`、`library` | 喜欢状态（`like.state` 为 none、liked 或 disliked）、播放列表 |
| `output` | 当前输出设备的名称与图标、是否跟随系统、可选设备列表 |
| `queue` | 播放队列：数量、位置、接下来的曲目，以及完整队列 |
| `params`、`state` | 持久皮肤参数与当前场景的临时状态 |

`host.layout` 给出内置宿主为皮肤安排的位置，单位为视口点：`artwork`、`lyrics`、`miniPlayer`、`canvas` 与 `window` 各含 x、y、width、height、midX、midY，`scale` 为宿主缩放。歌词显隐时随之更新。

窗口里的视口是 App 播放条上方的区域：`50%`、`vh` 与 `viewport.height` 都按这块区域计算，内容居中时便以播放条之上的高度为准，与内置皮肤一致。`host.layout.miniPlayer` 是播放条在视口下方的位置，`host.layout.window` 是从视口原点到窗口底边的整块区域；背景要铺到播放条下面时，把 `frame` 写成 `{"x": 0, "y": 0, "anchor": "topLeading", "width": "100%", "height": "=host.layout.window.height"}`。全屏时 `window` 与视口相同。把节点 `frame` 写成 `"x": "=host.layout.lyrics.x"` 并配 `"anchor": "topLeading"`，即可与内置皮肤对齐。`prefs.artBackgroundEnabled`、`prefs.artworkScale` 与 `prefs.miniPlayerAutoHide` 按当前界面读取用户设置。

播放队列可以完全由皮肤绘制。声明 `queue.items@1` 后，`queue.items` 是队列中每首曲目的记录（id、index、title、artist、album、duration、isCurrent），`queue.currentIndex` 为当前曲目的序号，`queue.title` 为队列名称，`queue.available` 表示当前来源有本地队列。用 `scroll` 包住 `repeat`，`scrollTo` 绑定 `queue.currentIndex`，只绘制可见的行；`artwork` 写上 `"track": "=item.id"` 即显示该曲目的缩略图；点击行时执行 `{"do": "queue.play", "value": "=item.index"}`。面板随 `host.queueVisible` 显隐，宽高、背景与排版都由皮肤决定。根节点的 `controls` 列出 `queue` 后，宿主不再叠加自己的队列面板。

`track.audio` 记录本地文件的 format、codec、bitrate、sampleRate、bitDepth、channels，以及 `isLossless` 与 `isHiRes`；外部来源为空记录。`track.hasMusicInfo` 表示有无音乐资料。

颜色提供 sRGB、Display P3 与 OKLCH 成员。`contrastRatio(a, b)` 给出 WCAG 对比度；`readable(背景, 候选1, 候选2)` 返回在背景上更易读的候选色，候选默认为白与黑，适合自绘面板上的文字。外部播放源没有本地 PCM 时，`audio.availability` 为 `externalAudioUnavailable`。只在可见节点引用音频时租用共享分析。

`clock.position` 是音频进度；`clock.lyrics` 是含视觉偏移的歌词文档时间。点击歌词使用 `seekToLyric` 或 `lyricTime(index)`，避免把视觉提前量带进跳转。

常量在编译时折叠；曲目、主题和参数按变化更新；只有引用时钟、音频或逐帧效果的节点进入显示时间线。进入时间线的节点每帧只重算逐帧的属性，其余属性保留到数据变化；但它每帧重建自身与全部子节点，所以逐帧的值应写在叶子节点上，不要写在包着控件的图层上。`camera`、`filter` 与 `bloom` 各自带时间线，只逐帧改变几何与着色，不重建子树，因此镜头漂移可以放心写在根图层上。`host.pointerIdle` 只在指针停下或再次移动时变化，可以放心用来隐藏整组控件；`host.pointerIdleTime` 逐帧更新。`host.pointerY` 是指针在视口中的纵坐标，按视口高度的 1/24 取整，只在跨过一格时变化；与 `host.pointerInside` 一起，可以让控件只在指针靠近时出现。`host.popoutOpen` 在弹出式控件栈展开时为真，可让控件在指针移到上方弹出的按钮时保持显示。时间线跟随显示器，不另设帧率上限。节点的时间线在它读到的输入全部静止后歇下：只依赖时钟、歌词或音频的节点在暂停的一刻停下；读 `time` 的节点随播放流缓缓停稳后停下；`follow()` 落定后停下；关键帧、`host.pointerIdleTime` 与 `time.free` 一直运行。

## 交互与动画

节点的 `on` 可以绑定 tap、doubleTap、longPress、hoverStart、hoverEnd、appear、disappear、scroll、magnify、dragStart、drag 与 dragEnd。拖动事件提供 `gesture.x/y/fractionX/fractionY/translationX/translationY`；滚轮提供 deltaX/deltaY 与 `precise`：触控板为 true，增量以点计；鼠标滚轮为 false，增量以行计。magnify 是触控板双指缩放，`gesture.magnification` 为相对上一次的变化量，张开为正，例如 `(state.zoom ?? 1) * (1 + gesture.magnification)`。操作可以是名称或对象：

```json
{"on":{"drag":{"do":"seek","value":"=gesture.fractionX * playback.duration"}}}
```

可调用播放、切歌、跳转、音量、播放顺序、喜欢、队列、歌词显隐、全屏、Quick Panel、设置、详情与编辑，以及皮肤重载、恢复和临时状态操作。操作由原有服务执行；来源不支持的控制应显示禁用状态。

菜单里的每一项也都是操作：`toggleDislike` 与 `setLike`（value 为 none、liked 或 disliked），`playlist.add`（value 为 `library.playlists` 中的 id）与 `playlist.new`，`track.delete`（先请用户确认），`musicInfo.open`，`artist.show` 与 `album.show`（全屏时先退出全屏），`output.select`（value 为设备 id，空字符串表示跟随系统），以及 `queue.show`、`queue.hide`、`lyrics.show` 与 `lyrics.hide`。

`transition` 让节点随 `visible` 淡入淡出，可用 `+` 叠加 `scale`、`blur`、`fromTop`、`fromBottom`、`fromLeading`、`fromTrailing`，例如 `"transition": "fade+fromBottom"`；写成记录时可加 token、duration、bounce、distance、scale 与 blur。`glyphs` 用于文字：进入时每个字各自从模糊中显现，先后错落，`stagger` 为 0 到 1，越大越分散；离开时按其余写法整体退场，例如 `"glyphs+blur"` 让旧行整体模糊淡出。带 transition 的节点隐藏后仍保留，不接收点击；减弱动态效果时只保留淡入淡出。

`key` 的值变化时，旧内容按 `transition` 离开、新内容进入，未写 transition 时淡入淡出；离开的一份朝反方向移动。把歌词行写成 `"key": "=lyrics.currentIndex"`，换行时上一行就会被新行推走。离开的一份默认只用一半时长，可在 transition 中以 `leaveDuration` 指定。

`"measure": true` 让节点表达式读到自身在场景中的位置与尺寸：`self.x`、`self.y`、`self.width`、`self.height`、`self.midX`、`self.midY`。适合把装饰对齐到文字，不要用来决定节点自身的尺寸。

`variants` 用 `when` 覆盖属性，可绑定 `self.hovered`、`self.pressed` 与 `self.dragging`。`animation` 使用 App 的 MotionKit token：microInteraction、control、layout、navigation、gestureSettle、emphasis、contentReplacement 与 backgroundTransition。写成记录时可指定 duration 与 bounce，仍随用户设置的动画速度缩放；写上 stiffness 时改为物理弹簧，另读 mass 与 damping。transition 与 enter 的记录同样适用。

`motion` 为节点及其子树重设 token，宿主组件的动画也随之改变：

```json
{"motion":{"speed":1.2,"emphasis":{"bounce":0.3},"control":{"stiffness":320,"damping":24}}}
```

表达式里也能直接用 MotionKit 的弹簧，时长都随用户的动画速度缩放，减弱动态效果时直接落到终点：

| 写法 | 结果 |
| --- | --- |
| `spring(token, 秒)` | 该 token 的弹簧在给定秒数时的进度，自 0 起、到 1 落定，带回弹的 token 会略过 1 |
| `springVelocity(token, 秒)` | 同一弹簧每秒的进度变化 |
| `focusHunt(秒, 种子, 方式)` | `bokeh` 滤镜的对焦抽动在该时刻的强度，0 到 1；方式可省略。让镜头推近、曝光等跟着虚焦一起动 |
| `springTo(秒, 时长, 弹性)` | 一段给定时长与弹性（0 到 1）的 MotionKit 弹簧在该时刻的进度；弹性为 0 时平滑落定、不越过 1。时长与弹性可以来自参数，让用户调整入场的长短与回弹 |
| `follow(目标, token, 缓起)` | 一个追随目标的弹簧；目标改变时从当前位置与速度接着追。token 省略时为 control。缓起（秒）让目标跳变后的拉力逐渐加大，镜头便像手持一样先倾身再移动 |
| `followVelocity(目标, token, 缓起)` | 同一追随弹簧的速度，单位为目标单位每秒，适合做拉伸与倾斜 |

token 可以是名称，也可以是与 `animation` 相同的记录。`spring` 适合有起点的动作，例如 `"=mix(-40, 0, spring(\"emphasis\", glyph.age))"` 让字带着回弹落位；`follow` 适合跟随会变的值，例如 `"=follow(self.hovered ? 1.08 : 1, \"emphasis\")"`。每个 `follow` 在每个节点与每个字上各有一份弹簧；数字写成 `spring(t, 频率, 阻尼)` 时仍是自 1 衰减到 0 的振荡。

场景的 `motion` 设置写在 `scene` 下，与 `root` 并列：

```json
{"motion":{
  "pause":"settle",
  "flow":"gestureSettle",
  "tokens":{"slam":{"token":"emphasis","duration":0.32,"bounce":0.45},"drift":{"token":"layout","duration":1.6}}
}}
```

- `pause` 决定暂停时自由运动怎么办。`settle`（默认）让 `time` 随播放流减速直到停下，播放时再加速回来；`continue` 让 `time` 按墙钟一直走；`stop` 在暂停的一刻停住。歌词与播放时钟始终如实。
- `flow` 是播放流使用的 token。`playback.flow` 读到这条曲线本身，播放时为 1，暂停后弹向 0，可以用来让光晕、镜头推近等随暂停收拢。
- `tokens` 定义皮肤自己的 token，每个都在一个内置 token 上重设参数（未写 `token` 时为 control），名称不能与内置 token 相同。`animation`、`transition`、`enter`、`spring` 与 `follow` 都可以用这些名称，用户的动画速度同样作用于它们。

`time.free` 是不受暂停影响的场景秒数，写给即使暂停也应缓缓流动的背景；读它的节点一直在时间线上，宜用在少数叶子节点。

`enter` 让节点首次出现时按给定方式进入，取值与 transition 相同，另可加 `delay`。写在根节点上，就是切换到这款皮肤时的入场；切换皮肤时，新旧场景先按 backgroundTransition 交叉淡化。减弱动态效果时只保留淡入淡出。

`keyframes` 使用 duration、repeat、trigger 和 tracks；每条数值轨道按等距采样点插值。`watch` 的 value 变化时执行 do；写上 `"initial": true` 时，节点出现时也执行一次。

`glyphMotion` 让 `text` 与 `lyricLine` 的每个字各自运动。它是一个记录，x、y、rotation、scale、opacity、blur 与 tint 各写一条表达式，围绕字的中心生效，表达式里可读 `glyph`：

| 成员 | 含义 |
| --- | --- |
| `index`、`count`、`char` | 字的序号、总字数与字本身 |
| `word`、`line` | 所在词与所在行的序号 |
| `start`、`end` | 字的开始与结束时刻，秒 |
| `age`、`progress` | 自开始以来的秒数，以及在本字时长内的 0 到 1 进度 |
| `lineAge` | 自本行第一个字开始以来的秒数 |
| `fontSize` | 该节点的字号，位移可写成字号的倍数 |

歌词行按逐词时间分配到字，没有逐词时间时按整行均分；普通文字以文字最近一次变化为起点，`progress` 恒为 1。静止时的字波与逐字进入可以合写：

```json
{"glyphMotion":{
  "y":"=sin(time * 2.4 - glyph.index * 0.5) * 3 + (1 - easeOut(glyph.age / 0.5)) * 18",
  "opacity":"=easeOut(glyph.age / 0.35)",
  "blur":"=(1 - easeOut(glyph.age / 0.4)) * 10"
}}
```

`easeIn`、`easeOut`、`easeInOut` 与 `backOut` 把 0 到 1 的进度映射为缓动曲线，`backOut` 带回弹。表达式里的时长宜写成 MotionKit token 的倍数：声明 `motion@1` 后，`motion.emphasis`、`motion.contentReplacement` 等给出各 token 按用户动画速度换算后的秒数，`motion.speed` 为相对标准速度的倍率；上例的 0.5 可写作 `motion.emphasis`。颜色同理取自 `theme.*`，皮肤便随歌曲换色。`presentation.controlForeground` 为 `fixedLight` 的皮肤画在暗场上，`theme.*` 与 `viewport.isDark` 始终按深色外观给出，日间模式下也取夜间配色。逐字运动与 `glyphs` 过渡可以叠加；`outline` 为每个字描边，写成宽度，或 `{width, color, hollow}`，`hollow` 只留外圈，适合做空心衬底大字；宽度为 0 时不描边。`extrude` 为每个字加上实心的厚度，写成深度，或 `{depth, angle, color, endColor}`，颜色由近及远渐变。glyphMotion 另有 `split`（红蓝错开的点数，逐字色散）与 `smearX`/`smearY`（沿位移方向的拖影）。`glow` 写成 `{radius, color, core}`，给每个字加上贴合字形的辉光：一层模糊副本取半径的七分之一（模糊最多 16 点），贴着字形形成亮边；更远的光是一团以字为中心、随距离近似平方衰减的圆形光晕，伸到字外约 1.5 倍半径，不用模糊，所以大半径也不拖慢渲染；这些都以加亮叠在字上，`core`（0 到 1）同时把字本身提亮到接近白色；亮度由 glyphMotion 的 `glow` 逐字决定（0 不亮，1 全亮，大于 1 是更亮的一闪），光随字一起运动；半径为 0 时不发光。在 `render: "gpu"` 图层里，辉光是真实的泛光：发光的字先画进一组逐级减半的高动态范围画面，各级按倍频程等权叠加，得到光在空气与镜头中散射的平方反比衰减，近处贴合字形，远处化作一层宽阔的薄晕，`radius` 即这层薄晕所及的距离。`strength`（默认 2.5）为曝光，`haze`（默认 1.4）加厚最外两级的薄晕，`saturation`（0 到 2，默认 1）调节光色浓淡，0 为无色的白光；光越淡，颜色越饱和，色相按色系偏移：淡黄偏向橙红，红偏向紫，绿与青偏向蓝。每个字的辉光取自己的颜色，同一画面最多分三组光色，更多颜色并入最接近的一组。减弱动态效果时逐字运动停止，描边与厚度保留。

文字默认按像素栅格绘制，缓慢缩放或平移时会一格一格地跳。`text` 写上 `"subpixel": true` 后，每个字按字形轮廓填充，位置与字号连续变化，适合镜头缓推和逐字慢移的大字；表情符号等没有轮廓的字仍按原方式绘制。

歌词字体可以跟随 App：声明 `lyrics.prefs@1` 后，`lyrics.prefs.fontFamily`、`lyrics.prefs.fontFamilyCJK` 与 `lyrics.prefs.fontWeight`（thin 到 black）给出用户为当前皮肤选定的歌词字体与字重，这款皮肤没有单独设置时为全局歌词设置。译文另有 `lyrics.prefs.translationFontFamily` 与 `lyrics.prefs.translationFontWeight`。字号有两种读法：`lyrics.prefs.fontSize` 与 `translationFontSize` 是原生歌词实际使用的点数，已按全屏画布与窗口内全屏放大换算；`lyrics.prefs.fontScale` 与 `translationFontScale` 是用户设定相对这一界面默认字号的倍数，1 为默认，适合按视口自定字号的皮肤。皮肤可以把它作为一个字体选项，与自带的字体并列，例如 `"font": "=params.font == 'app' ? lyrics.prefs.fontFamilyCJK : 'youyou-yisong'"`。

逐词排版用文字测量与列表函数完成，不必手算：

| 函数 | 结果 |
| --- | --- |
| `measureText(文字, 字号, 字重, 字体)` | 文字宽度（点），字重与字体可省略；字体可用包内字体的名称 |
| `measureEach(列表, 字号, 字重, 字体)` | 每项的宽度；列表项为文字或含 `text` 的记录 |
| `textHeight(文字, 字号, 宽度, 字重, 字体, 行距, 行数上限)` | 文字按宽度折行后的高度（点），与 `render: "gpu"` 图层的文字排版一致；宽度为 0 时排成一行，后四项可省略 |
| `cumsum(列表)`、`offsets(列表, 间距)` | 累加和；每项的起点 |
| `pluck(列表, 字段)` | 取出每条记录的一个字段 |
| `argmax(列表)`、`argmin(列表)` | 最大、最小值的序号 |
| `addEach(列表, 数或列表)`、`mulEach(列表, 数或列表)` | 逐项相加、相乘 |

海报式的整行构图写成包内脚本：用 `host.measureText` 量出每个词，按自己的规则安排位置，换行时把结果存入 state。

例如每个词的起点：`"=offsets(measureEach(lyrics.current.words, 64, \"heavy\"), 12)[index]"`；唱得最久的词：`"=argmax(addEach(pluck(lyrics.current.words, \"end\"), mulEach(pluck(lyrics.current.words, \"start\"), -1)))"`。

`camera` 写在 `layer` 上，记录含 x、y、zoom、rotation、rotationX、rotationY 与 perspective。层内定位的子节点随镜头平移与缩放，幅度乘以 `1 / (1 + depth)`：`depth` 为 0 时完全跟随，越大越远、移动越少，负值则更近。旋转作用于整层，rotationX 与 rotationY 带透视。把镜头写成随 `time` 缓慢变化的表达式，画面便有持续的漂移与缓推。

逐帧相机可写 `"sharedMotion": true`，在图层上统一施加公共平移与缩放。子节点仍保留各自的景深差，图层内的 AppKit 和视频视图继续按原方式绘制。

`camera.rasterize` 默认为 `false`。设为 `true` 会在透视旋转前把图层内容绘制到一张透明位图，适用于文字和形状等由 SwiftUI 绘制的图层。相机以常量 `true` 启用时，共同的平移与放大作用于合成后的位图，拉远在绘制位图时完成，位图始终约为画面大小；图层中各节点仍按自身的 `depth` 保留景深差。每次图层内容更新会增加一次离屏绘制。包含视频、AppKit 视图或其他原生平台内容的图层应使用默认值。

`contextMenu` 是带 title 与 do 的菜单项数组。宿主保留全局快捷键、空白处恢复菜单和全屏所需入口。

## 材质、效果和素材

`material` 支持 ultraThin、thin、regular、thick、ultraThick、bar。`glass` 支持 regular、clear、identity、tint、interactive、shape 与 cornerRadius；`glassGroup` 提供融合容器。

通用效果有 opacity、rotation、scale、offsetX/Y、blur、brightness、contrast、saturation、grayscale、hueRotation、invert、blendMode、clip 与 mask。`blendMode` 可用 multiply、screen、overlay、darken、lighten、colorDodge、colorBurn、softLight、hardLight、difference、exclusion、hue、saturation、color、luminosity、plusLighter、plusDarker 与 destinationOut，任意节点都能使用，光斑常用 plusLighter。`"group": true` 先合成整个子树，内部的混合只作用于彼此，不影响下层。显式 border、shadow 是作者效果，不改变 App 设置的默认样式。

`filter` 给节点套上内置着色器，写成一个 `{type, ...}` 或按顺序叠加的数组：

| type | 参数 | 效果 |
| --- | --- | --- |
| `chromatic` | amount、angle | RGB 色散，红蓝沿角度错开 |
| `glitch` | amount、slice、rate、intensity | 水平切片随机错位，rate 为每秒跳变次数，intensity 为发作比例 |
| `motionBlur` | x、y、samples | 沿位移方向的运动模糊 |
| `scanlines` | spacing、intensity、speed | 扫描线 |
| `wave` | amplitude、wavelength、speed | 缓慢的液态扭曲 |
| `grain` | amount、rate | 胶片颗粒，每秒跳动 rate 次（默认 8；0 为每帧更新），颗粒细密，亮部与辉光保留约一半 |
| `lut` | file、amount | 按 `.cube` 文件（3D 或 1D，sRGB 编码）给子树调色。file 是包内相对路径，amount（0 到 1，默认 1）为强度。`render: "gpu"` 的图层在最后一道放大时调色，位于虚焦、畸变、色散和边缘模糊之后、颗粒之前。其他节点按滤镜顺序调色。文件在后台载入，路径为空或载入期间沿用原色。可以用 `choice` 参数在包内的多份 LUT 之间切换 |
| `fov` | distortion、chromatic、blur、start | 镜头边缘：广角畸变、沿径向逐段展开的色散和边缘模糊；chromatic 以点计，最大 24，色散后的画面再做边缘模糊，start 控制色散和模糊的起点。各项为 0 时画面原样，可随表达式在 0 与其他值间平滑变化；子树先按节点画框裁切 |
| `bokeh` | at、seed、wave、radius、amount、speed、glow、threshold、swirl、hold、breathing、detail | 仅用于 `render: "gpu"` 的图层。镜头在歌词时间 at（秒）抛虚一到三下，每下之间拉回到几乎清晰，一下比一下小，最后逐渐回到清晰；换行时已开始的抽动照常走完，hold（0 到 1）大于 0 时一直按该强度虚焦，便于调整光斑。每一点化作光圈形状的圆盘，边缘清楚，文字留下圆润的轮廓：radius 为最大虚焦半径（点），wave 选对焦方式（0 搜焦、1 颤动、2 恍惚、3 抽动，省略时按 seed 随机），speed 为快慢，amount 为整体强度，glow（0 到 1，默认 0.6）决定亮处在光斑里的分量，越大亮点散成的光斑越亮越实，threshold（0 到 1，默认 0.3）为算作亮处的起点，swirl（0 到 1，默认 0.3）让越靠四角的圆盘越扁、略带旋转，breathing 让画面随虚焦轻微放大，detail 调整光斑源的精细度（默认 1，越大越细、GPU 用时越多）。同一 at 与 seed 的几层一起抽动；at 为空时不触发 |

`custom` 调用包内预编译的着色器库，写法为 `{type: "custom", library: "fx.metallib", function, kind, args, reach, animated}`。`kind` 为 layer（可采样子树）、color 或 distortion；函数在 SwiftUI 规定的参数之后依次收到 `float2 size`（含外扩的画布尺寸）、`float time`，再按顺序收到 `args`：数为 float，2 至 4 个数的列表为 float2 至 float4，更长的列表为浮点数组（函数收到 `device const float *` 与 `int` 两个参数，可写 `=spectrum(64)`），颜色为 half4，`{image: "textures/noise.png"}` 为包内图片（`texture2d<half>`）。`reach` 为最大采样偏移，`animated` 为 true 时逐帧更新。用 `xcrun -sdk macosx metal -o fx.metallib fx.metal` 编译，源码以 `#include <SwiftUI/SwiftUI_Metal.h>` 开头，函数标注 `[[stitchable]]`。

`bloom` 让子树的亮部向外泛光并叠加回去，写成半径，或 `{radius, intensity, threshold}`。滤镜与泛光按效果所需的范围外扩绘制，不会被节点边框裁掉；它们作用于整棵子树，应写在文字或装饰等叶子节点上，不要套在整屏图层上。减弱动态效果时，glitch、wave 与 grain 停止跳动。

设置中的「歌词与皮肤渲染质量」同时决定滤镜、泛光与 `camera.rasterize` 位图的分辨率：低、中、高分别以 0.5x、0.75x、1x 绘制，再放大到画面。半径、偏移与间距始终以点书写，宿主按分辨率换算，各档构图一致，差别只在清晰度。`custom` 着色器与只含 scanlines、grain 的滤镜始终以原分辨率绘制。场景皮肤的选项中同样列出这项设置。

节点的 `resolution`（0.25 至 1）让其内容以更低分辨率绘制后放大，再乘以渲染质量，适合雾、渐变等柔和的背景；节点自身的滤镜与泛光随后按常规分辨率叠加，颗粒依旧清晰。

整屏画面可在 layer 上写 `render: "gpu"`，其子节点合进一张 Metal 画面，按自己的显示时钟绘制，画面静止时随之停歇。子节点可用 `shape`（矩形、圆、椭圆与 `path`，可带 `stroke`、`trimStart`、`trimEnd`、`rotation`、`blur`，`path` 还可带 angular `gradient` 遮罩）、`gradient`、`fog`、`particles`、`comet` 与 `text`，也可嵌套 `layer`（可带 `offsetX`、`offsetY`）与 `layout: "free"` 的 `repeat`；属性与表达式照常书写，粒子可带 `motionBlur`，嵌套节点各按自己的 `depth` 取镜头视差，未写时随父层。画面空无一物时随之隐去。`text` 取字体、字号、字距、行距、对齐、行数、颜色、旋转、缩放、偏移、`blur`、`glow` 与 `glyphMotion`，字形经 Core Text 排版后按字号缓存，在 GPU 上逐字绘制，适合整屏逐字运动的歌词。图层的镜头取 `x`、`y`、`zoom`、`perspective`、`rotation`、`rotationX` 与 `rotationY`，倾斜与同一镜头下的其他图层重合；滤镜取 `grain`、`fov`、`bokeh` 与 `lut`，虚焦、畸变、光谱色散和边缘模糊依次在这张画面上完成，放大时依次叠加调色与颗粒；`resolution` 决定这张画面的分辨率。

`motionBlur` 让整张画面按一帧的位移留下拖尾，写成 0 到 2 的份额，0 关闭。位移是镜头运镜与元素自身运动之和：镜头平移、推拉时，画面里的字、粒子、圆环一起拖；镜头静止时，逐字入场、粒子飞行仍有自己的拖尾。每个字、每颗粒子、每个圆环只在自己的像素上沿自身轨迹积分，采样数随位移长度自适应，静止时不足半像素即跳过，因此没有额外的一遍全屏处理，字的拖尾也不会被相邻的元素拖出色边。悬浮控件不在 `render: "gpu"` 图层里，保持清晰。

`fog` 节点绘制域扭曲的分形噪声雾，`colors` 给出由暗到亮的两色（只给一色时从透明过渡），`size` 为一团雾的尺度（点），另有 `speed`、`warp`（折叠强度）与 `gain`（对比）。叠一层低不透明度的 fog 即是网易云式的流雾，换成暗红两色便是流体底。

`render: "gpu"` 下的 fog 可加 `zones`，让雾自己带上颜色：整团雾取第一色，其余颜色只在零星的小片里晕染进来，镜头移过时偶尔拍到。`zones` 写一列颜色，或写 `{colors, lightness, chroma, size, share, scrollX, scrollY}`：相近的色调并作一色，`lightness` 把各色拉到同一明度、只留少许高低，`chroma` 缩放彩度（点缀色比主色更淡，暗处彩度另有上限），`size` 为一片色斑的尺度（点），`share` 为色斑出现的多少（0 到 1），`scrollX`、`scrollY` 让色斑单独滑动，未写时随雾本身。色斑边缘随雾的浓淡起伏，中心仍留两成主色；交融在感知色彩空间里进行，明度不变。几层滚速与 `depth` 不同的雾各带色斑，镜头移动时前后错开，背景便有纵深。`theme.artSwatches` 是封面插画背景小色块所用的色板，封面素净时只有一色的几种深浅，丰富时可到六色，与 `zones` 配合，背景的色彩便随封面的丰富程度变化。

`shape` 的 `stroke` 改为描线，写成宽度，或 `{width, color, cap, join, dash}`；同时写了 `color` 时才另行填充。`trimStart` 与 `trimEnd` 截取线段，让 `trimEnd` 随时间从 0 走到 1，就是逐笔画出的线圈。

`spectrum`、`waveform`、`meter` 直接绘制共享音频。`particles` 提供确定性的粒子画布：默认是缓缓上浮的尘点，`soft`（点）让每颗尘点的边缘逐渐虚化，比整层 `blur` 省去每帧一次全层模糊；写上 `lifetime`（秒）后改为发射，每颗粒子在随机位置出现，沿 `angle` 度方向、在 `spread` 度内散开，以 `speed` 点每秒飞行，在一生中淡入淡出，`trail` 给出以秒计的拖尾，`colors` 为随机取用的颜色。`turbulence`（点）与 `wander`（弧度每秒）让粒子沿前进方向两侧缓慢摆动，`curve` 让路线逐渐弯曲；粒子始终向前，拖尾是它刚走过的路径，画成一条由细到粗、由暗到亮的连续光带。配合 `blendMode: plusLighter`，就是带拖尾的彗星与火花。

`comet` 是绕目标飞行的单颗彗星，以节点中心为目标：`orbit` 为 [rx, ry] 椭圆，`progress` 从 0 到 1 表示飞行进度，通常由时钟算出；它从 `angle` 所指的一侧远处飞来，绕目标转过 `sweep` 度后飞离。`trail` 为拖尾占整段飞行的比例，`size` 为实心彗头半径，`width` 为拖尾最宽处。节点框需要容纳整段轨迹，约为椭圆的 5.6 倍。

在 `render: "gpu"` 的图层里，`comet`、带 `trail` 的发射粒子，以及带 `stroke` 的圆、椭圆与 `path` 可写 `brush`，画成颜料笔触。`brush` 可以是 0 到 1 的数，也可以写成 `{amount, dry, wobble, warp, seed}`：`amount` 决定干笔油彩的质感：起伏而参差的轮廓、刷毛拖出的条纹与颜料的厚薄，每一笔的刷毛数与粗糙程度各不相同，0 保持平滑线条；`dry` 决定颜料向笔画末端干涸、露出飞白的程度；圆和椭圆保持原有轮廓，描边由许多交叠的短笔铺成，边缘带毛边，`wobble` 决定每笔的错位与斜度；`path` 的每一笔起笔略钝，收笔收成笔尖，毛分叉而干，粗细随运笔缓缓起伏，`wobble` 决定压力起伏与线条轻微的摆动；`warp`（默认同 `wobble`）让图形像手画一样走形：整体略微弯斜，线条细细抖动，闭合的图形收笔越过起点又错开，不严丝合缝。走形与笔触按图形自身的坐标固定，镜头移动时不变。彗星画成笔触时，`width` 即笔画半宽，不受彗头大小限制，笔画以圆润的湿笔头收尾，省去实心彗头；粒子的 `width` 按各自的彗头大小缩放。`shadow` 可以写成数组，按顺序叠加多层。`video.path` 加载静音循环视频，隐藏时停止；动态封面使用 `artwork`，沿用 App 的共享解码。

`fonts` 列出包内 ttf、otf 或 ttc 路径。字体按可见场景持有，退出后释放登记。

Metal 节点用 `path` 指向源码，`function` 默认为 skinFragment，须为常量标识符。源码定义以下两种函数之一：

```cpp
float4 skinFragment(float2 uv, constant SkinUniforms& u, SkinInputs in)          // 完整输入
float4 skinFragment(float2 uv, constant SkinUniforms& u, texture2d<float> artwork) // 只取封面
```

`uv` 从左上角 (0, 0) 到右下角 (1, 1)。`SkinUniforms` 逐帧提供：

| 字段 | 含义 |
| --- | --- |
| resolution、pixelsPerPoint | 画面像素尺寸、每点像素数 |
| time、deltaTime、frame | 场景时间、距上一帧的秒数、帧序号 |
| lyricsTime、progress、duration、playing | 歌词时间、播放进度 0 至 1、时长、是否在播放 |
| bass、lowMid、mid、vocal、treble、level、beat | 分频能量、整体响度与鼓点脉冲，均为 0 至 1 |
| pointer、pointerInside | 指针在节点内的 uv 位置，及指针是否在节点内 |
| accent、averageColor、palette[4] | 主题色、封面平均色与封面调色板，sRGB rgba |
| spectrumCount、waveformCount、argCount、imageCount | 下列数据的数量 |

完整输入还带来以下数据，由节点属性决定：

| 属性 | 着色器中读取 | 说明 |
| --- | --- | --- |
| `spectrum`（默认 64，至多 256） | `skinSpectrum(in, x)` | 30 Hz 至 16 kHz 按对数分布的频段，0 至 1，x 从 0 到 1 插值 |
| `waveform`（默认 256，至多 2048） | `skinWaveform(in, x)` | 实时波形，−1 至 1 |
| `args`（至多 16 项） | `skinArg(in, i)` | 任意表达式，逐帧求值：数填 x，至多 4 个数的列表填 x 至 w，颜色为 rgba |
| `images`（至多 4 张） | `skinImage(in, i, uv, blur)` | 包内图片，边缘重复，适合噪声与纹理 |
| `feedback: true` | `skinPrevious(in, uv)` | 上一帧画面，以半精度保存，用于拖尾、积累与流体 |
| — | `skinArtwork(in, uv, blur)` | 封面；`blur` 为 mip 层级，0 最清晰，每加 1 尺寸减半 |

`in.position` 为像素坐标；`skinLinear` 与 `skinRepeat` 是两种现成的采样器。节点的 `resolution`（0.25 至 1）决定着色器画面的分辨率，柔和的背景用 0.5 至 0.75 足够。输出按预乘 alpha 与下层叠加，写 1 即为不透明。

编译异步进行，错误显示在该节点。源码至多 1 MB；图片与封面按长边至多 2048 像素解码并生成 mip；GPU 上至多排队两帧，较慢的着色器只降低自己的帧率；GPU 耗时连续 60 帧超过每帧 25 毫秒时，节点停用并显示原因。请从[流彩样例](examples/skins/shader/shaders/flow.metal)开始。

## 参数、安装和开发

`parameters` 声明 id、title、defaultValue、control，支持 toggle、range、choice 和 color。`isUserVisible` 为 true 的参数出现在设置的皮肤选项与全屏快速面板中，只为少量重要选项开启。`visibleWhen` 可以引用其他 params，支持参数联动。相邻且 `section` 相同的参数归在同一小标题下。普通用户不编辑位置。场景用到 `control.miniPlayer` 时，快速面板同时列出播放条的可视化、自动隐藏与材质；用到 `background.host` 时，窗口设置列出艺术背景开关。每个参数占一行：名称在左，range 为定宽滑块，数值在滑块末尾。

参数默认立即生效。皮肤只在换行时读取某个值（例如把字体或节奏写进整行的版面）时，给该参数加 `"applies": "nextLine"`；用户调整这些参数后，设置与快速面板的参数列表底部会临时出现一行小字，列出刚调整的参数，提示从下一行歌词起生效；几秒后淡出。立即生效的参数省略该字段。

`presentation.panelPlacement` 决定全屏快速面板的位置：`center`（默认）、`leading` 或 `trailing`。面板从所在一侧滑入，关闭时滑回并淡出；居中时轻轻上浮。快速面板的歌词页只列出皮肤读到的设置：场景挂载 `lyrics.native` 或 `lyrics.panel` 时列出全部；自绘歌词的场景保留字体与时间轴，声明 `lyricsLead` 后时间轴只留整体提前量。快速面板打开时 `host.quickPanelVisible` 为 true，皮肤可以借此收起自己的控件。

`presentation.scrollVolume` 设为 true 后，在场景任意位置滚动即可调节音量，并显示与内置皮肤相同的音量胶囊。指针下有列表、文本等可滚动内容，或节点绑定了 `scroll`，或快速面板、歌曲详情正在显示时，滚动交给它们。

查看详情默认在窗口内弹出玻璃卡片。`presentation.trackDetail` 设为 `scene` 后改由场景绘制：`host.detailVisible` 为 true 时，`host.detail` 提供 `title`、`artist`、`album`、`heading`、`text` 与 `note`，皮肤执行 `trackDetail.close` 结束显示。

场景的右键菜单列出当前歌曲的喜欢、添加到播放列表、查看详情、编辑歌曲信息与从资料库删除；从某个播放列表开始播放时，另有从该播放列表移除。支持自定义皮肤的版本在菜单末尾另有刷新皮肤与恢复默认皮肤。

`lyricsLead` 是宿主识别的保留参数，单位为秒。声明后，它只把该皮肤的歌词时钟提前对应秒数，不改变原生歌词与其他皮肤；`clock.lyrics`、`lyrics.current` 与逐词进度都会一起前移。正值提前，默认 0.4 表示提前 400 毫秒。

App 随附的字潮和 AM 可导出，原生皮肤仍由 App 管理。导入 ZIP 时先确认包内的脚本、着色器、字体和视频，再安装。同 ID 的已导入包可以替换或另存副本，失败时保留当前版本。同 ID 的关联目录优先，其次是已导入的包，再次是随附版本。移除当前包后，若有同 ID 的版本就继续使用该皮肤，否则切回默认皮肤。

“关联目录”登记作者目录，并监听文件变更；选中存放多个皮肤包的文件夹时，其中每个含 `manifest.json` 的子目录都会关联。错误保留上一次可用场景；移除关联保留源码。右键刷新或设置内重载会重新编译当前包。

从仓库根目录检查和打包：

```sh
python3 scripts/check-skin-package.py --all-examples
/usr/bin/ditto -c -k docs/examples/skins/vinyl /tmp/vinyl.zip
```

结构检查不解析表达式。App 已运行且 Automation 获准时，使用现有 CLI 的通用调用：

```sh
muci-automation automation call skin.capabilities
muci-automation automation call skin.check --params-json '{"directory":"/absolute/author/directory"}'
muci-automation automation call skin.reload --params-json '{"skinID":"example.vinyl"}'
muci-automation automation call skin.runtime
```

skin.check 的 `frameNodes` 按重建子节点数从多到少列出进入时间线的节点及其逐帧属性，据此把逐帧的值移到叶子节点上。skin.runtime 返回活动节点、帧求值次数与音频读取者计数；CPU、内存和帧时间仍需性能工具测量。

## 样例

- [唱片](examples/skins/vinyl/manifest.json)：自绘控件、旋转封面与音频绑定。
- [浮光](examples/skins/glass/manifest.json)：可切换的艺术背景、随背景明暗变化的播放条、可调长度与显隐，以及在快速面板切换歌词高亮与层次。
- [字里行间](examples/skins/poster/manifest.json)：全文歌词自绘、当前行逐词染色、滚动和点击跳转，控件在指针静止后淡出。
- [流彩](examples/skins/shader/manifest.json)：Metal 背景、粒子与原生歌词。
