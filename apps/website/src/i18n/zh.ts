import type { Dictionary } from "./en";

export const zh: Dictionary = {
  meta: {
    title: "Codans：并行运行你的 Coding Agent",
    description:
      "一款 macOS 原生终端，把所有项目、worktree 和 Coding Agent 放进同一个窗口，并告诉你哪些 Agent 在等你。",
    changelogTitle: "更新日志：Codans",
  },
  nav: {
    changelog: "更新日志",
    github: "GitHub",
    download: "下载",
    otherLocale: "English",
    otherLocaleLabel: "Switch to English",
  },
  hero: {
    title: "在一个窗口里，<br />并行运行所有 Coding Agent。",
    lede: "Codans 是为使用 Coding Agent 工作的人做的 macOS 原生终端。每个任务一个 worktree，每个 Agent 一个 pane，哪些在工作、哪些在等你，一眼可见。",
    download: "下载 macOS 版",
    copy: "复制",
    copied: "已复制",
    requirements: "免费开源。需要 macOS 14 或更高版本，Apple Silicon。",
    tabsLabel: "产品导览",
    steps: [
      {
        name: "开始",
        views: [
          {
            shot: "hero-start",
            label: "新建 Agent",
            caption: "选项目、起分支名、写提示词。Codans 创建 worktree，并在里面启动 Agent。",
            alt: "Codans 窗口上的 New Agent 对话框：项目、名为 feat/digest-email 的新 worktree、提示词，已选 Claude Code。",
          },
        ],
      },
      {
        name: "工作",
        views: [
          {
            shot: "hero-build",
            label: "边写边跑",
            caption: "左边 Agent 写代码，右边是它不能弄坏的开发服务器。",
            alt: "宽 pane 里 Claude Code 正在工作，旁边的窄 pane 显示开发服务器的请求日志。",
          },
          {
            shot: "hero-review",
            label: "边做边审",
            caption: "左边是 Codex，右边实时显示这个 worktree 的 diff。改动发生的同时你就在读。",
            alt: "窄 pane 里是 Codex，旁边的宽 pane 是终端 diff 查看器和改动的文件。",
          },
          {
            shot: "hero-team",
            label: "多 Agent 协作",
            caption: "五个 Agent 在同一个 worktree：一个主导，一个审查，其余负责测试、基准和文档。",
            alt: "隐藏侧栏的五个 pane：第一列 Claude Code，第二列 Codex 和 omp，第三列 OpenCode 和 Pi。",
          },
        ],
      },
      {
        name: "交付",
        views: [
          {
            shot: "hero-pr",
            label: "Pull Request",
            caption: "窗口顶栏显示当前 worktree 的 PR。鼠标移上去查看检查结果，然后合并。",
            alt: "窗口顶栏下方的 PR 弹出面板：标题、作者、三项通过的检查和 Merge 按钮。",
          },
        ],
      },
    ],
  },
  agents: {
    lead: "支持你已经在终端里用的 Agent：",
    names: ["Claude Code", "Codex", "OpenCode", "Pi", "omp", "Gemini CLI"],
    tail: "以及任何有 CLI 的工具。",
  },
  agentFirst: {
    name: "Agent 优先",
    title: "围绕 Agent 设计，而不是围绕编辑器。",
    lede: "普通终端把 Agent 当成又一个进程。Codans 知道哪些 pane 在跑 Agent、各自处于什么状态，也知道怎么启动、排队、恢复和交接它们的工作。",
    cards: [
      {
        shot: "agents-view",
        title: "Agents View",
        body: "所有项目里的每个 Agent 和它的实时状态：工作中、等待你、已完成、空闲。点一行直达对应的 pane。",
        alt: "Agents View 面板里有十三个 Agent，其中两个在等待回答，多个已完成。",
      },
      {
        shot: "new-agent",
        title: "New Agent",
        body: "按 <kbd>⌘⇧N</kbd>，选项目、起分支名、写提示词。worktree、标签页和 Agent 一起启动。",
        alt: "New Agent 对话框：项目、新 worktree、提示词和 Agent。",
      },
      {
        shot: "skills",
        title: "提示词里补全 Skill",
        body: "输入当前 Agent 的 Skill 前缀，Codans 会补全这个 Agent 已安装的 Agent Skill，并显示说明。",
        alt: "在提示词里输入 /review 后，上方弹出 Agent Skill 列表。",
      },
      {
        shot: "queue",
        title: "命令队列",
        body: "Agent 忙的时候，先把后面的提示词排好。每条可以在当前任务结束后发送、立即发送，或者定时发送。",
        alt: "某个 pane 的 Queued Commands 列表，四条提示词等待当前任务结束。",
      },
      {
        shot: "sessions",
        title: "会话历史",
        body: "一个 worktree 下所有的 Claude Code 和 Codex 会话，最新在前。可以在新标签页、原地或分屏里恢复。",
        alt: "Agent Sessions 弹出面板：四个 Claude Code 会话和两个 Codex 会话。",
      },
      {
        shot: "profile",
        title: "Agent Profile",
        body: "命名的启动预设：Agent、模型、推理强度、执行模式、打开位置、额外参数和环境变量。",
        alt: "设置里的 Agents 面板，一个以 Opus 模型和 plan 模式启动 Claude Code 的 profile。",
      },
      {
        shot: "handoff",
        title: 'Hand Off 与 Workflow <span class="tag">Beta</span>',
        body: "把任务交给另一个 Agent。由完成工作的 Agent 写交接说明，接收方在旁边启动。Workflow 用 YAML 把这些步骤串成循环，比如作者与审阅者。",
        alt: "Hand Off 面板里的 Agent profile 列表，已选中 Codex Reviewer。",
      },
      {
        shot: "notifications",
        title: "来自 Agent 的通知",
        body: "Agent 停下来提问或完成一轮时，它所在的 worktree 会出现铃铛。Unread 过滤器只列出这些 worktree，macOS 通知点一下直达 pane。",
        alt: "打开 Unread 过滤器的侧栏：六个带铃铛的 worktree。",
      },
      {
        shot: "persistence",
        title: "关掉窗口，会话还在",
        body: "退出 Codans，Agent 继续工作。每个 pane 都运行在一个很小的会话守护进程里，下次启动时所有终端连同内容立刻回来。",
        alt: "退出对话框：六个 pane 正忙，可选 Keep session running、Snapshot and exit 或 Cancel。",
      },
    ],
    cli: {
      title: "给 Agent 自己用的 CLI 和 Agent Skill",
      body: [
        "窗口里的一切都能通过 <code>codans</code> 命令操作，它在每个 pane 的 PATH 里。Agent 用它创建 worktree、启动其他 Agent、等待它们并读取输出。",
        "应用自带的 Agent Skill 会教 Agent 使用这些命令。用 <code>codans skill install</code> 安装。",
      ],
    },
  },
  parallel: {
    name: "并行",
    title: "多个项目，多个 worktree，一个窗口。",
    lede: "并行工作失败，往往是因为你跟丢了。Codans 把整棵树放在侧栏，每条工作线都有自己的目录。",
    points: [
      {
        title: "worktree 是一等公民",
        body: "项目下列出它的 git worktree。每个 worktree 有自己的目录、分支、标签页和 pane，两个 Agent 不会改同一份代码，除非你有意如此。",
      },
      {
        title: "每一层都有状态",
        body: "侧栏显示每个 worktree 的 diff 大小、PR、正在运行的命令和未读铃铛。不用点进去就知道哪里有变化。",
      },
      {
        title: "切换没有延迟",
        body: "每个 worktree 的标签页和分屏布局都保持原样，重启之后也一样。",
      },
    ],
    sidebarAlt: "侧栏里有五个项目和十二个 worktree，多数 worktree 显示 diff 大小和 PR 编号。",
    teamTitle: "五个 Agent，一个 worktree",
    teamBody: "导览里那个布局的录屏：每个 pane 是一个 Agent，在同一个分支上各做各的事。",
    teamAlt: "五个 Agent pane 同时输出内容的录屏。",
    layoutTitle: "每个 pane 都是真正的终端",
    layoutBody:
      "渲染基于 libghostty，Ghostty 里能跑的这里都能跑：Agent、系统监视器、git 提交图，或者等测试时玩一局贪吃蛇。",
    layoutAlt: "四个 pane：Claude Code、htop、贪吃蛇和 git log 提交图。",
    statsTitle: "用真实 Agent 测出来的数字",
    stats: [
      { value: "14", label: "个 Agent 同时运行，分布在 5 个项目的 20 个 pane 里" },
      { value: "0.6%", label: "Agent 等待时 Codans 的 CPU 占用，输出滚动时约 5%" },
      { value: "200 MB", label: "屏幕上显示一个 worktree 时应用的内存" },
      { value: "1.1 MB", label: "每个让 pane 保持存活的会话守护进程" },
    ],
    statsNote:
      "Codans 0.12.1，8 核 Apple Silicon Mac，16 GB 内存。没打开过的终端保持休眠。20 个终端全部打开过之后，应用占用约 600 MB。Agent 自身的内存另算。",
  },
  pr: {
    name: "Pull Request",
    title: "从创建到合并，PR 不用离开窗口。",
    lede: "Codans 通过你已经登录的 <code>gh</code> 和 <code>glab</code> CLI 读取 PR。它自己不发任何 HTTP 请求，也不保存 token。",
    cards: [
      {
        shot: "pr-popover",
        title: "GitHub",
        body: "worktree 上的徽标跟随它分支的 PR。弹出面板显示检查结果，可以合并、关闭、标记为可评审，或者重跑失败的检查。",
        alt: "GitHub PR 弹出面板：三项通过的检查和 Merge (squash) 按钮。",
      },
      {
        shot: "mr-popover",
        title: "GitLab",
        body: "Merge Request 用法相同，支持 gitlab.com 和自托管实例，pipeline 的 job 就是检查项。",
        alt: "GitLab MR 弹出面板：三个通过的 pipeline job 和 Merge (squash) 按钮。",
      },
    ],
    capsTitle: "在窗口里能做的事",
    caps: [
      "每个 worktree 上的 PR 和 MR 徽标",
      "检查与 pipeline 状态，工作时实时更新",
      "合并提交、squash 合并、rebase 合并",
      "把草稿标记为可评审",
      "重跑失败的检查",
      "评审状态，以及合并被阻塞的原因",
    ],
    diffTitle: "先读改动",
    diffBody:
      "只读 diff 窗口展示 Agent 改了什么：未提交的改动，或者这个分支相对基线新增的全部内容。支持统一和分栏视图，带文件树，不挤占终端。",
    diffAlt: "分栏布局的 diff 窗口，文件树里有十一个改动的文件。",
  },
  more: {
    name: "其他",
    title: "配置一次，之后一直依赖的那些部分。",
    projects: {
      title: "项目管理",
      items: [
        {
          shot: "filter-workspace",
          title: "Workspace",
          body: "把多个仓库的 checkout 编成一组来做一件事。一个分支名，每个项目各 checkout 一份。",
          alt: "打开 Workspace 过滤器的侧栏：一个 workspace，含 default 组和一个 release 组。",
        },
        {
          shot: "filter-remote",
          title: "远程项目",
          body: "通过 SSH 使用另一台机器上的 worktree 和 pane，沿用你现有的 SSH 配置。",
          alt: "打开 Remote 过滤器的侧栏：名为 Mac mini 的主机上的一个项目。",
        },
        {
          shot: "filter-pr",
          title: "过滤器",
          body: "把侧栏收窄到远程项目、workspace、有 PR 的 worktree，或者有未读通知的 worktree。",
          alt: "打开 PR 过滤器的侧栏：六个带 PR 的 worktree。",
        },
      ],
    },
    themes: {
      title: "主题",
      body: "内置全部 463 个 Ghostty 主题。浅色和深色各选一个，窗口跟随系统外观，并从终端取色。",
      items: [
        { shot: "theme-tokyonight", name: "TokyoNight Storm" },
        { shot: "theme-rosepine", name: "Rose Pine Dawn" },
        { shot: "theme-gruvbox", name: "Gruvbox Dark" },
        { shot: "theme-latte", name: "Catppuccin Latte" },
        { shot: "theme-mocha", name: "Catppuccin Mocha" },
      ],
      altSuffix: "主题下的 Codans 窗口",
    },
    speed: {
      title: "效率",
      items: [
        {
          shot: "palette",
          title: "命令面板",
          body: "<kbd>⌘P</kbd> 查找所有操作：切换 worktree、启动 Agent、运行命令、分屏。",
          alt: "命令面板，输入 agent 后列出 Launch Agent 操作。",
        },
        {
          shot: "run-menu",
          title: "项目命令与全局命令",
          body: "把构建、测试、开发服务器命令绑定到 Run 按钮和快捷键。Codans 会读取 package.json、Makefile、justfile、Cargo.toml 等文件，把找到的命令列出来。",
          alt: "Run 菜单：四个项目命令，以及在 package.json 里找到的脚本。",
        },
        {
          shot: "shortcuts",
          title: "完整的快捷键",
          body: "每个操作都有快捷键，可以修改、停用，也可以搜索。",
          alt: "设置里的 Shortcuts 面板：操作与按键组合的表格。",
        },
        {
          shot: "open-in",
          title: "一个按键打开编辑器",
          body: "<kbd>⌘O</kbd> 在 VS Code、Cursor、Zed、Xcode 或 JetBrains IDE 中打开 worktree。Codans 不是 IDE，也不打算成为 IDE。",
          alt: "Open in 菜单：编辑器、终端和 git 客户端列表。",
        },
      ],
    },
  },
  cta: {
    title: "从你手头正开着的项目开始。",
    source: "阅读源码",
  },
  footer: {
    releases: "发布版本",
    issues: "问题反馈",
    repo: "代码仓库",
  },
  changelog: {
    title: "更新日志",
    subtitle: "Codans 的每一个版本，最新在前。",
    latest: "最新",
    kinds: {
      Added: "新增",
      Changed: "变更",
      Deprecated: "弃用",
      Removed: "移除",
      Fixed: "修复",
      Security: "安全",
    },
  },
};
