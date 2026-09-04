import 'package:flutter_test/flutter_test.dart';
import 'package:inksync/reader/content.dart';

void main() {
  test('白名单标签被解析为对应 BlockKind', () {
    final blocks = ContentParser.parse(
      '<h1>标题</h1><p>正文 <em>斜体</em> 与 <strong>粗体</strong></p>'
      '<blockquote>引用</blockquote><p>换<br/>行</p><hr/><p><img src="a.png"/>图</p>',
    );
    // h1 → heading level 1
    expect(blocks.first.kind, BlockKind.heading);
    expect(blocks.first.level, 1);
    // 段落含 em / strong 文本
    final p = blocks.firstWhere((b) => b.kind == BlockKind.paragraph && b.plainText.contains('正文'));
    expect(p.plainText, contains('斜体'));
    expect(p.plainText, contains('粗体'));
    // blockquote → quote
    expect(blocks.any((b) => b.kind == BlockKind.quote), isTrue);
    // hr → separator
    expect(blocks.any((b) => b.kind == BlockKind.separator), isTrue);
    // img → ImageNode
    final imgBlock = blocks.firstWhere((b) => b.inlines.any((n) => n is ImageNode));
    final img = imgBlock.inlines.whereType<ImageNode>().single;
    expect(img.src, 'a.png');
  });

  test('非白名单标签被忽略，文本保留', () {
    final blocks = ContentParser.parse('<div><script>alert(1)</script>可见文本</div>');
    final text = blocks.map((b) => b.plainText).join('');
    expect(text, contains('可见文本'));        // 文本保留
    expect(text, contains('alert(1)'));         // 白名单只过滤标签，不剥离标签内文本
    expect(text, isNot(contains('<script>')));  // 但标签节点被解析消耗，不残留为原始标签
  });

  test('br 转为换行，plainText 含 \\n', () {
    final blocks = ContentParser.parse('<p>第一行<br/>第二行</p>');
    expect(blocks.single.plainText, '第一行\n第二行');
  });

  test('HTML 实体被解码', () {
    final blocks = ContentParser.parse('<p>a &lt;b&gt; &amp; c</p>');
    expect(blocks.single.plainText, 'a <b> & c');
  });
}
