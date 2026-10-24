## ADDED Requirements

### Requirement: 年级选择与课本同步

系统 SHALL 允许用户选择年级（1-6年级），并展示对应深圳小学英语课本的课程内容。

#### Scenario: 选择年级

- **WHEN** 用户打开 APP 并选择年级（如"2年级"）
- **THEN** 系统加载该年级对应的课本章节列表
- **AND** 显示每课的完成进度

#### Scenario: 课程内容展示

- **WHEN** 用户选择某一课
- **THEN** 系统展示该课的单词列表、句型、学习目标
- **AND** 标注已学/未学状态

### Requirement: 课程内容数据管理

系统 SHALL 按照深圳英语课本（沪教版/上海教育出版社）的章节结构组织内容。

#### Scenario: 课程内容结构

- **WHEN** 系统加载课程内容
- **THEN** 按课本章节组织：Unit → Lesson → Words/Sentences
- **AND** 每课包含单词（含发音音频、图片）、句型、学习目标

#### Scenario: 内容更新

- **WHEN** 课本版本更新
- **THEN** 系统支持内容热更新，无需重新发布 APP
