# Worktree 创建层级原型

在仓库根目录启动本地预览：

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory design-previews
```

打开 <http://127.0.0.1:8765/worktree-hierarchy.html>。

- 点击目录后，分支栏切换到该目录；切换分支同步更新侧栏标签。
- 从任意目录新建 worktree，创建来源在打开弹窗时确定，支持继续嵌套。
- 目录路径是节点身份，父目录和同级创建顺序单独保存；分支名不参与层级计算。
- 演示状态保存在当前浏览器、当前地址的本地存储中，刷新后保留；可使用“重置演示”恢复初始树。
- 这是独立交互原型：目录和 Git 操作为模拟，不会创建真实目录、切换真实分支或修改 CodexBar 原生应用。

模型回归测试：

```sh
node --test --experimental-test-coverage Tests/DesignPreviewTests/WorktreeHierarchyTests.mjs
```
