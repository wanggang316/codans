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
    lede: "Codans 是一款 macOS 原生终端，把所有项目、worktree 和 Agent 并排放在一起，并告诉你哪些在工作、哪些在等你。",
    download: "下载 macOS 版",
    copy: "复制",
    copied: "已复制",
    requirements: "免费开源。需要 macOS 14 或更高版本，Apple Silicon。",
    shotAlt: "Codans 窗口：左侧是项目与 worktree 侧栏和 Agents View，右侧是运行着 Coding Agent 的终端。",
  },
  states: [
    { key: "working", name: "工作中", detail: "Agent 正在执行" },
    { key: "blocked", name: "等待你", detail: "它在等你回答" },
    { key: "done", name: "已完成", detail: "完成了一轮，你还没看" },
    { key: "idle", name: "空闲", detail: "停在输入提示符" },
  ],
  agents: {
    lead: "支持你已经在终端里用的 Agent：",
    names: ["Claude Code", "Codex", "OpenCode", "Pi"],
    tail: "以及任何有 CLI 的工具。",
  },
  features: [
    {
      shot: "new-agent",
      title: "每个任务，<br />一个独立的 worktree。",
      body: [
        "按 <kbd>⌘⇧N</kbd>，选项目、起分支名、写下提示词。Codans 创建 git worktree，在里面打开标签页并启动 Agent。其他任务原地继续运行。",
      ],
      alt: "New Agent 对话框：项目、新 worktree、Agent 和提示词。",
    },
    {
      shot: "agents-view",
      title: "一眼看出<br />哪个 Agent 在等你。",
      body: [
        "Agents View 列出所有项目里的每个 Agent 和它的实时状态。有 Agent 停下来提问或完成一轮时，你会收到通知，点一下直达对应的 pane。",
      ],
      alt: "Agents View：处于工作中、等待你、已完成和空闲状态的 Agent。",
    },
    {
      shot: "handoff",
      title: "把任务从一个 Agent<br />交接给另一个。",
      body: [
        "由完成工作的 Agent 自己写交接说明。Codans 在旁边启动接收方，并把说明作为它的第一条提示词，换模型不丢上下文。",
        'Workflow 用 YAML 把这些步骤串成循环，比如作者与审阅者。<span class="tag">实验性</span>',
      ],
      alt: "并排的两个 pane：一个 Agent 交出任务，另一个按交接说明开始工作。",
    },
    {
      shot: "review",
      title: "审阅改动，然后合并。",
      body: [
        "只读 diff 窗口展示 Agent 改了什么，不挤占终端。每个 worktree 旁边显示 GitHub 和 GitLab 的 PR 状态，合并、检查、重跑都是一次点击。",
      ],
      alt: "diff 窗口，以及某个 worktree 的 Pull Request 弹出面板。",
    },
  ],
  cli: {
    title: "在任意 pane 里<br />用脚本驱动。",
    body: [
      "窗口里的一切都能通过 <code>codans</code> 命令操作。它在每个 pane 的 PATH 里，你和你的 Agent 都可以创建 worktree、启动其他 Agent、读取彼此的输出。",
      "应用自带 Agent Skill，教会你的 Agent 使用这些命令。",
    ],
  },
  more: {
    title: "还包括",
    items: [
      {
        title: "内置 Ghostty",
        body: "终端渲染基于 libghostty：快、GPU 绘制，并兼容你的 Ghostty 使用习惯。",
      },
      {
        title: "SSH 远程项目",
        body: "在另一台机器上使用 worktree 和 pane，沿用你现有的 SSH 配置。",
      },
      {
        title: "Workspace",
        body: "把多个仓库的 checkout 编成一组，让一个 Agent 跨仓库工作。",
      },
      {
        title: "一个快捷键打开编辑器",
        body: "在 VS Code、Cursor、Zed 或 Xcode 中打开任意 worktree。Codans 不是 IDE，也不打算成为 IDE。",
      },
      {
        title: "项目级运行命令",
        body: "把构建、测试、开发服务器命令绑定到 Run 按钮和快捷键。",
      },
      {
        title: "键盘优先",
        body: "命令面板，以及可自定义的全套快捷键。",
      },
    ],
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
