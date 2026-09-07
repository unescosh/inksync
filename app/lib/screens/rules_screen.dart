import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../reader/rules.dart';
import '../state/providers.dart';

/// 自定义高亮规则编辑器。
///
/// 规则存在本地 SQLite 的 `rules` 表，**随 WebDAV 三端同步**，
/// 因此在一台设备上配好的规则，另外两台打开就有。
///
/// 改动路径统一为：改库 → 写 outbox → markDirty()（3 秒后自动同步）。
class RulesScreen extends ConsumerWidget {
  const RulesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rowsAsync = ref.watch(rawRulesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('高亮规则'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'presets') await _importPresets(ref);
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'presets',
                child: Text('导入内置预设'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          const _PreviewBox(),
          const Divider(height: 1),
          Expanded(
            child: rowsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (rows) {
                if (rows.isEmpty) {
                  return const Center(child: Text('还没有规则，点右下角添加'));
                }
                return ReorderableListView.builder(
                  itemCount: rows.length,
                  onReorder: (from, to) => _reorder(ref, rows, from, to),
                  itemBuilder: (context, i) => _RuleTile(row: rows[i], index: i, total: rows.length),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(context, ref, null),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _importPresets(WidgetRef ref) async {
    for (final r in RulePresets.all) {
      await _upsert(ref, r);
    }
  }

  Future<void> _reorder(WidgetRef ref, List<RuleRow> rows, int from, int to) async {
    final list = List<RuleRow>.of(rows);
    final moved = list.removeAt(from);
    list.insert(to > from ? to - 1 : to, moved);
    for (var i = 0; i < list.length; i++) {
      await _upsert(ref, _rowToRule(list[i]).copyWith(sortOrder: i));
    }
  }

  void _edit(BuildContext context, WidgetRef ref, RuleRow? row) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RuleEditorSheet(existing: row),
    );
  }
}

class _RuleTile extends ConsumerWidget {
  const _RuleTile({required this.row, required this.index, required this.total});

  final RuleRow row;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rule = _rowToRule(row);
    return ListTile(
      key: ValueKey(row.id),
      leading: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: Color(rule.bgColorValue).withOpacity(rule.bgOpacity),
          border: Border.all(color: Color(rule.colorValue)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(Icons.format_color_text, size: 16, color: Color(rule.colorValue)),
      ),
      title: Text(rule.name),
      subtitle: Text(
        '${_kindLabel(rule.kind)} · ${rule.pattern.isEmpty ? '(无)' : _short(rule.pattern)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: row.enabled,
            onChanged: (v) => _upsert(ref, rule.copyWith(enabled: v)),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'edit':
                  final r = row;
                  // ignore: use_build_context_synchronously
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _RuleEditorSheet(existing: r),
                  );
                case 'delete':
                  await _delete(ref, rule);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(value: 'edit', child: Text('编辑')),
              PopupMenuItem<String>(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  static String _kindLabel(RuleKind k) => switch (k) {
        RuleKind.regex => '自定义正则',
        RuleKind.quote => '引号',
        RuleKind.bookTitleMark => '书名号',
        RuleKind.paren => '括号',
        RuleKind.personName => '人名表',
        RuleKind.dialogue => '对话提示',
        RuleKind.keywordList => '关键词表',
      };

  static String _short(String s) =>
      s.length > 40 ? '${s.replaceAll('\n', ' / ').substring(0, 40)}…' : s.replaceAll('\n', ' / ');
}

// ─────────────────────────── 编辑弹层 ───────────────────────────

class _RuleEditorSheet extends ConsumerStatefulWidget {
  const _RuleEditorSheet({this.existing});

  final RuleRow? existing;

  @override
  ConsumerState<_RuleEditorSheet> createState() => _RuleEditorSheetState();
}

class _RuleEditorSheetState extends ConsumerState<_RuleEditorSheet> {
  late final TextEditingController _name;
  late final TextEditingController _pattern;
  late RuleKind _kind;
  late int _color;
  late int _bg;
  late double _opacity;
  late bool _bold;
  late int _priority;
  late Set<RuleScope> _scope;

  static const _colors = <int>[
    0xFFD32F2F,
    0xFF1565C0,
    0xFF2E7D32,
    0xFFEF6C00,
    0xFF6A1B9A,
    0xFF00838F,
  ];
  static const _bgs = <int>[
    0xFFFFF176,
    0xFFBBDEFB,
    0xFFC8E6C9,
    0xFFFFE0B2,
    0xFFE1BEE7,
    0xFFB2EBF2,
  ];

  @override
  void initState() {
    super.initState();
    final r = widget.existing == null ? null : _rowToRule(widget.existing!);
    _name = TextEditingController(text: r?.name ?? '');
    _pattern = TextEditingController(text: r?.pattern ?? '');
    _kind = r?.kind ?? RuleKind.regex;
    _color = r?.colorValue ?? _colors.first;
    _bg = r?.bgColorValue ?? _bgs.first;
    _opacity = r?.bgOpacity ?? 0.35;
    _bold = r?.bold ?? false;
    _priority = r?.priority ?? 0;
    _scope = r?.scope ?? {RuleScope.novel};
  }

  @override
  void dispose() {
    _name.dispose();
    _pattern.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.existing == null ? '新建规则' : '编辑规则',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '规则名称', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<RuleKind>(
              value: _kind,
              decoration: const InputDecoration(labelText: '类型', border: OutlineInputBorder()),
              items: [
                for (final k in RuleKind.values)
                  DropdownMenuItem<RuleKind>(
                    value: k,
                    child: Text(_RuleTile._kindLabel(k)),
                  ),
              ],
              onChanged: (v) => setState(() => _kind = v ?? RuleKind.regex),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pattern,
              maxLines: 4,
              minLines: 2,
              decoration: InputDecoration(
                labelText: '内容',
                hintText: _hintFor(_kind),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final c in _colors)
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: Color(c),
                      child: _color == c ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final c in _bgs)
                  GestureDetector(
                    onTap: () => setState(() => _bg = c),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Color(c).withOpacity(_opacity),
                        border: Border.all(
                          color: _bg == c ? Theme.of(context).colorScheme.primary : Colors.transparent,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('底色浓度'),
                Expanded(
                  child: Slider(
                    value: _opacity,
                    min: 0,
                    max: 1,
                    onChanged: (v) => setState(() => _opacity = v),
                  ),
                ),
                Checkbox(
                  value: _bold,
                  onChanged: (v) => setState(() => _bold = v ?? false),
                ),
                const Text('加粗'),
              ],
            ),
            Row(
              children: [
                const Text('优先级'),
                Expanded(
                  child: Slider(
                    value: _priority.toDouble(),
                    min: 0,
                    max: 50,
                    divisions: 50,
                    label: '$_priority',
                    onChanged: (v) => setState(() => _priority = v.round()),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final s in RuleScope.values)
                  FilterChip(
                    label: Text(s == RuleScope.novel ? '小说' : '漫画'),
                    selected: _scope.contains(s),
                    onSelected: (v) => setState(() {
                      final next = Set<RuleScope>.from(_scope);
                      v ? next.add(s) : next.remove(s);
                      _scope = next;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _save,
              child: const Text('保存（并同步到其他端）'),
            ),
          ],
        ),
      ),
    );
  }

  static String _hintFor(RuleKind k) => switch (k) {
        RuleKind.regex => r'例如：【[^】]{1,40}?】',
        RuleKind.quote => '成对符号，多组用 | 分隔：\u201c\u201d|「」',
        RuleKind.bookTitleMark => '成对符号：《》|〈〉',
        RuleKind.paren => '成对符号：（）|()',
        RuleKind.personName => '人名表，逗号/顿号/空格/换行分隔：\n张无忌, 赵敏',
        RuleKind.dialogue => r'留空则用默认：(?m)^[^“”"\n]{0,20}[：:]',
        RuleKind.keywordList => '关键词，每行一个',
      };

  Future<void> _save() async {
    final base = widget.existing == null ? null : _rowToRule(widget.existing!);
    final rule = (base ??
            HighlightRule(
              id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
              name: _name.text.trim(),
              kind: _kind,
            ))
        .copyWith(
      name: _name.text.trim().isEmpty ? '未命名规则' : _name.text.trim(),
      kind: _kind,
      pattern: _pattern.text,
      colorValue: _color,
      bgColorValue: _bg,
      bgOpacity: _opacity,
      bold: _bold,
      priority: _priority,
      scope: _scope,
      sortOrder: base?.sortOrder ?? 100,
    );
    await _upsert(ref, rule);
    if (mounted) Navigator.of(context).pop();
  }
}

// ─────────────────────────── 预览 ───────────────────────────

class _PreviewBox extends ConsumerWidget {
  const _PreviewBox();

  static const String _sample = '''他翻开《九阴真经》，低声道：“这门功夫，练错了会走火入魔。”
周芷若【冷笑】一声：那你还要练？
他答：“若不练，如何护得住你。”''';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final set = ref.watch(ruleSetProvider);
    const engine = RuleEngine();
    final segments = engine.match(_sample, set);
    final base = Theme.of(context).textTheme.bodyMedium!;

    final spans = <TextSpan>[];
    var cursor = 0;
    for (final s in segments) {
      if (s.start > cursor) {
        spans.add(TextSpan(text: _sample.substring(cursor, s.start)));
      }
      final r = set.byId[s.ruleId];
      spans.add(
        TextSpan(
          text: _sample.substring(s.start, s.end),
          style: TextStyle(
            color: Color(r?.colorValue ?? 0xFF000000),
            fontWeight: r?.bold == true ? FontWeight.bold : null,
            backgroundColor: r == null ? null : Color(r.bgColorValue).withOpacity(r.bgOpacity),
          ),
        ),
      );
      cursor = s.end;
    }
    if (cursor < _sample.length) {
      spans.add(TextSpan(text: _sample.substring(cursor)));
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('实时预览（${set.rules.length} 条规则生效）',
              style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 6),
          RichText(text: TextSpan(style: base, children: spans)),
        ],
      ),
    );
  }
}

// ─────────────────────────── 写库 + 写 outbox ───────────────────────────

HighlightRule _rowToRule(RuleRow r) => HighlightRule(
      id: r.id,
      name: r.name,
      kind: RuleKind.values.firstWhere(
        (k) => k.name == r.kind,
        orElse: () => RuleKind.regex,
      ),
      pattern: r.pattern,
      caseSensitive: r.caseSensitive,
      colorValue: r.colorValue,
      bgColorValue: r.bgColorValue,
      bgOpacity: r.bgOpacity,
      bold: r.bold,
      italic: r.italic,
      underline: r.underline,
      priority: r.priority,
      scope: r.scopeCsv
          .split(',')
          .map((s) => RuleScope.values.firstWhere(
                (v) => v.name == s.trim(),
                orElse: () => RuleScope.novel,
              ))
          .toSet(),
      enabled: r.enabled,
      sortOrder: r.sortOrder,
      hlc: r.hlc,
      updatedBy: r.updatedBy,
      deleted: r.deleted,
    );

/// 所有规则改动都走这里：改库 → 写 outbox → 触发同步。
Future<void> _upsert(WidgetRef ref, HighlightRule rule) async {
  final db = ref.read(databaseProvider);
  final clock = await ref.read(hlcClockProvider.future);
  final deviceId = await ref.read(deviceIdProvider.future);
  final hlc = clock.tick();

  final row = rule.copyWith(hlc: hlc.encode(), updatedBy: deviceId);
  final payload = row.toJson();
  payload['scopeCsv'] = row.scope.map((s) => s.name).join(',');
  payload.remove('scope');

  await db.into(db.rules).insertOnConflictUpdate(RulesCompanion.insert(
        id: row.id,
        name: row.name,
        kind: row.kind.name,
        pattern: row.pattern,
        caseSensitive: row.caseSensitive,
        colorValue: row.colorValue,
        bgColorValue: row.bgColorValue,
        bgOpacity: row.bgOpacity,
        bold: row.bold,
        italic: row.italic,
        underline: row.underline,
        priority: row.priority,
        scopeCsv: row.scope.map((s) => s.name).join(','),
        enabled: row.enabled,
        sortOrder: row.sortOrder,
        hlc: row.hlc,
        updatedBy: deviceId,
        deleted: row.deleted,
      ));

  await db.into(db.outbox).insert(OutboxCompanion.insert(
        entityType: 'rule',
        entityId: row.id,
        op: 'upsert',
        payloadJson: jsonEncode(payload),
        hlc: hlc.encode(),
      ));

  ref.read(syncTriggerProvider.notifier).markDirty();
}

/// 删除用墓碑（deleted=true），不是物理删除 —— 否则离线端会把它"复活"。
Future<void> _delete(WidgetRef ref, HighlightRule rule) async {
  final db = ref.read(databaseProvider);
  final clock = await ref.read(hlcClockProvider.future);
  final deviceId = await ref.read(deviceIdProvider.future);
  final hlc = clock.tick();

  await (db.update(db.rules)..where((t) => t.id.equals(rule.id))).write(
    RulesCompanion(deleted: const Value(true), hlc: Value(hlc.encode()), updatedBy: Value(deviceId)),
  );
  await db.into(db.outbox).insert(OutboxCompanion.insert(
        entityType: 'rule',
        entityId: rule.id,
        op: 'delete',
        payloadJson: jsonEncode({
          'id': rule.id,
          'deleted': true,
          'hlc': hlc.encode(),
          'updatedBy': deviceId,
        }),
        hlc: hlc.encode(),
      ));

  ref.read(syncTriggerProvider.notifier).markDirty();
}
