# sgfs: site generator from scratch

A simple markdown parser and html file mapper written in zig. It contains a markdown parser in `src/markdown.zig`, which currently supports headers, lists, paragraphs, code blocks, italic, bold, monospace, and markdown metadata. The generator currently maps html files in a specific format to a resulting directory. It does not handle invalid markdown that well since I don't care about it too much.

```
$ sgfs indir -gen -outdir
```

The basic layout is contained in the `src/generator.zig`.
