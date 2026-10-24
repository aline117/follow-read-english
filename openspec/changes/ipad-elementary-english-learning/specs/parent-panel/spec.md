## ADDED Requirements

### Requirement: 家长控制面板

系统 SHALL 提供家长端入口，需验证才能进入。

#### Scenario: 家长验证

- **WHEN** 用户点击"家长入口"
- **THEN** 系统要求输入 4 位 PIN 码
- **AND** 验证成功后进入家长面板

### Requirement: 学习报告

系统 SHALL 向家长展示孩子的学习数据，此功能为**必需功能**。

#### Scenario: 每日报告

- **WHEN** 家长查看学习报告
- **THEN** 显示当日学习时长、新学单词数、正确率
- **AND** 以图表形式展示

#### Scenario: 进度追踪

- **WHEN** 家长查看课程进度
- **THEN** 显示每课完成度、已掌握单词、待复习单词
- **AND** 标注薄弱单词（正确率低的）

#### Scenario: 周报总结

- **WHEN** 家长查看每周报告
- **THEN** 显示本周学习天数、总学习时长、新学单词总数、进步趋势

### Requirement: 兑换规则管理

系统 SHALL 让家长创建和管理兑换规则。

#### Scenario: 创建规则

- **WHEN** 家长创建新规则
- **THEN** 设置名称、星星成本、每日/每周兑换上限
- **AND** 保存后立即可见

#### Scenario: 审核兑换

- **WHEN** 孩子申请兑换
- **THEN** 家长收到通知并可批准/拒绝
- **AND** 批准后自动扣除星星

### Requirement: 多孩子支持

系统 SHALL 支持多个孩子 Profile 切换。

#### Scenario: Profile 切换

- **WHEN** 家长添加多个孩子
- **THEN** 每个孩子有独立的学习数据和星星
- **AND** 可一键切换 Profile
