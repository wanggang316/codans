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
    views: [
      {
        shot: "hero-palette",
        label: "命令面板",
        alt: "火星山丘前的深色 Codans 窗口，命令面板已打开：New Agent、New Workspace、Open Project 等操作。侧栏的 Agents View 里有正在工作、等待批准和已完成的 Agent。",
      },
      {
        shot: "hero-start",
        label: "开始：New Agent 对话框",
        alt: "粉色沙丘前的浅色 Codans 窗口，上面是 New Agent 对话框：inboxlm 项目、名为 feat/label-rules 的新 worktree、提示词，已选 Claude Code。",
      },
      {
        shot: "hero-build",
        label: "工作：Agent 和开发服务器",
        alt: "Gruvbox Dark 主题的 Codans 窗口，背景是地球的蓝色边缘，月球在窗口后面。宽 pane 里 Claude Code 正在工作，旁边的窄 pane 运行开发服务器。",
      },
      {
        shot: "hero-review",
        label: "工作：Agent 和实时 diff",
        alt: "Rosé Pine Dawn 主题的 Codans 窗口，背景是蓝色波浪。窄 pane 里是 Codex，旁边是终端 diff 查看器。",
      },
      {
        shot: "hero-team",
        label: "工作：一个 worktree 里的五个 Agent",
        alt: "月球表面上方、隐藏侧栏的深色 Codans 窗口。五个 pane：第一列 Claude Code，第二列 Codex 和 omp，第三列 OpenCode 和 Pi。Claude Code 正在等待推送的批准。",
      },
      {
        shot: "hero-pr",
        label: "交付：GitHub Pull Request",
        alt: "纯绿色背景上的浅色 Codans 窗口。顶栏下方的 PR 弹出面板显示三项通过的检查和 Merge 按钮。",
      },
    ],
  },
  agentFirst: {
    title: "围绕 Agent 设计，而不是围绕编辑器。",
    lede: "Codans 知道哪些 pane 在跑 Agent、各自是什么状态，也能启动、排队、恢复和交接它们的工作。",
    cards: [
      {
        shots: ["agents-view-1", "agents-view-2", "agents-view-3"],
        title: "Agents View",
        body: "所有项目里的每个 Agent 和它的实时状态。点一行直达对应的 pane。",
        alt: "Agents View 面板：一个 Agent 等待批准，三个在工作，随后其中两个完成。",
      },
      {
        shots: ["new-agent"],
        title: "New Agent",
        body: "按 <kbd>⌘⇧N</kbd>，选项目、起分支名、写提示词。worktree 和 Agent 一起启动。",
        alt: "New Agent 对话框：项目、新 worktree、提示词和 Agent。",
      },
      {
        shots: ["queue-1", "queue-2"],
        title: "命令队列",
        body: "Agent 忙的时候先把提示词排好：当前任务结束后发送、立即发送，或定时发送。",
        alt: "Command Queue 对话框里一条每 30 分钟重复的提示词，随后是三条排队命令的列表。",
      },
      {
        shots: ["sessions-1", "sessions-2", "sessions-3"],
        title: "会话历史",
        body: "一个 worktree 下所有的 Claude Code 和 Codex 会话。可以在新标签页、原地或分屏里恢复。",
        alt: "Agent Sessions 弹出面板里的六个会话、Resume in 菜单，以及在新分屏里恢复的会话。",
      },
      {
        shots: ["profile"],
        title: "Agent Profile",
        body: "启动预设：Agent、模型、推理强度、执行模式、打开位置、参数和环境变量。",
        alt: "设置里的 Agents 面板，一个以 Opus 模型和 plan 模式启动 Claude Code 的 profile。",
      },
      {
        shots: ["handoff"],
        title: 'Workflow <span class="tag">Beta</span>',
        body: "带着交接说明把任务交给另一个 Agent，或把多个 Agent 串成循环，比如作者与审阅者。",
        alt: "Hand Off 面板里的 Agent profile 列表，已选中 Codex Reviewer。",
      },
      {
        shots: ["notifications-1", "notifications-2"],
        title: "通知",
        body: "Agent 提问或完成时，它所在的 worktree 会出现铃铛。点 macOS 通知直达 pane。",
        alt: "macOS 通知中心里的两条 Codans 通知：Claude 在等待输入，以及一个任务已完成。随后是打开 Unread 过滤器的侧栏：六个带铃铛的 worktree。",
      },
      {
        shots: ["persistence"],
        title: "关掉窗口，会话还在",
        body: "退出 Codans，Agent 继续工作。下次启动时所有终端都回来。",
        alt: "退出对话框：六个 pane 正忙，可选 Keep session running、Snapshot and exit 或 Cancel。",
      },
      {
        shots: ["cli-1", "cli-2"],
        title: "CLI 和 Agent Skill",
        body: "窗口里的一切都是一条 <code>codans</code> 命令。Agent 用它创建 worktree、启动其他 Agent、读取输出。",
        alt: "终端里运行 codans agent status，随后是一条让 Codex 用 codans skill 新开 worktree 并启动 Agent 的提示词。",
      },
    ],
  },
  parallel: {
    title: "多个 worktree，高效并行。",
    lede: "每个任务一个 worktree，同时推进。所有 worktree 的状态都在侧栏里。",
    points: [
      {
        title: "一个任务，一个 worktree",
        body: "每个 worktree 有自己的目录、分支、标签页和 pane，Agent 不会改到同一份代码。",
      },
      {
        title: "状态都在侧栏",
        body: "每个 worktree 的 diff 大小、PR、正在运行的命令和未读铃铛。不用点进去就知道哪里有变化。",
      },
      {
        title: "切换不丢现场",
        body: "标签页和分屏布局保持原样，重启之后也一样。",
      },
      {
        title: "为多终端并行而优化",
        body: "为大量终端并行工作做了深度优化，保持低内存、高效运行。没打开过的终端保持休眠。",
      },
    ],
    sidebarAlt:
      "侧栏里有五个项目和十二个 worktree，多数 worktree 显示 diff 大小和 PR 编号。",
  },
  pr: {
    title: "PR，从创建到合并。",
    lede: "Codans 通过你已经登录的 <code>gh</code> 和 <code>glab</code> CLI 读取 PR。它自己不发任何 HTTP 请求，也不保存 token。",
    // The capabilities that Settings > Git Platforms lists, in the same order.
    platforms: [
      {
        id: "github",
        name: "GitHub",
        via: "通过 <code>gh</code> CLI。",
        items: [
          { text: "Pull Request 徽标" },
          { text: "检查状态" },
          { text: "Create merge commit" },
          { text: "Squash and merge" },
          { text: "Rebase and merge" },
          { text: "标记为可评审" },
          { text: "重跑失败的检查" },
          { text: "评审状态" },
        ],
      },
      {
        id: "gitlab",
        name: "GitLab",
        via: "通过 <code>glab</code> CLI，支持 gitlab.com 和自建实例。",
        items: [
          { text: "Merge Request 徽标" },
          { text: "Pipeline 状态" },
          { text: "Merge" },
          { text: "Squash and merge" },
          { text: "Rebase and merge", unsupported: "由项目的合并方式决定" },
          { text: "标记为就绪" },
          { text: "重试失败的 Pipeline 作业" },
          { text: "评审状态" },
        ],
      },
    ],
  },
  more: {
    title: "配置一次，之后一直依赖的那些部分。",
    projects: {
      title: "项目管理",
      // One item for each sidebar filter, in the order of the filter bar in the app.
      items: [
        {
          id: "remote",
          tab: "Remote",
          title: "远程项目",
          body: "通过 SSH 使用另一台机器上的 worktree 和 pane，沿用你现有的 SSH 配置。",
          alt: "打开 Remote 过滤器的 Codans 窗口：名为 Mac mini 的主机上的一个项目。",
        },
        {
          id: "workspace",
          tab: "Workspace",
          title: "Workspace",
          body: "把多个仓库的 checkout 编成一组来做一件事：一个分支名，每个项目各 checkout 一份。",
          alt: "打开 Workspace 过滤器的 Codans 窗口：一个 workspace，含 default 组和一个 release 组。",
        },
        {
          id: "pr",
          tab: "PR",
          title: "Pull Request",
          body: "只看有 PR 的 worktree，带 PR 编号和 diff 大小。",
          alt: "打开 PR 过滤器的 Codans 窗口：六个带 PR 的 worktree。",
        },
        {
          id: "unread",
          tab: "Unread",
          title: "未读通知",
          body: "只看 Agent 提问或完成后你还没看过的 worktree。",
          alt: "打开 Unread 过滤器的 Codans 窗口：六个带铃铛的 worktree。",
        },
      ],
    },
    themes: {
      title: "主题",
      body: "内置全部 463 个 Ghostty 主题。浅色和深色各选一个，窗口跟随系统外观，并从终端取色。",
      altSuffix: "主题下的 Codans 窗口",
    },
    speed: {
      title: "快捷操作",
      items: [
        {
          shot: "palette",
          title: "命令面板",
          body: "<kbd>⌘P</kbd> 查找所有操作。",
          alt: "命令面板，输入 agent 后列出 Launch Agent 操作。",
        },
        {
          shot: "run-menu",
          title: "运行命令",
          body: "把构建、测试、开发服务器绑定到 Run 按钮。Codans 会从项目文件里找出脚本。",
          alt: "Run 菜单：四个项目命令，以及在 package.json 里找到的脚本。",
        },
        {
          shot: "shortcuts",
          title: "快捷键",
          body: "每个操作都有快捷键，可以修改。",
          alt: "设置里的 Shortcuts 面板：操作与按键组合的表格。",
        },
        {
          shot: "open-in",
          title: "打开编辑器",
          body: "<kbd>⌘O</kbd> 在你的编辑器里打开 worktree。",
          alt: "Open in 菜单：编辑器、终端和 git 客户端列表。",
        },
      ],
    },
  },
  cta: {
    title: "从你手头正开着的项目开始。",
    source: "在 GitHub 上查看",
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
