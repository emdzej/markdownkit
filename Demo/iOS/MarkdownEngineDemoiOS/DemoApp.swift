import SwiftUI
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                EditorScreen()
                    .navigationTitle("MarkdownEngine")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

struct EditorScreen: View {
    @State private var text = sample

    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.services.syntaxHighlighter = HighlighterSwiftBridge()
        config.services.latex = SwiftMathBridge()
        return config
    }

    var body: some View {
        NativeTextViewWrapper(text: $text, configuration: configuration)
            .ignoresSafeArea(.container, edges: .bottom)
    }
}

let sample = """
# Hello from iOS

This is **bold**, *italic*, ~~struck~~, and `inline code`. A [link](https://example.com).

## Lists

- First item
- Second item
  - Nested item
1. One
2. Two

## Tasks

- [ ] Port the editor to UIKit
- [x] Compile the shared core for iOS
- [ ] WYSIWYG tables

> A blockquote with *emphasis*.

---

```swift
struct Note {
    let title: String
}
```

Inline math $e^{i\\pi} + 1 = 0$ and a block:

$$
\\int_0^1 x^2 \\, dx = \\frac{1}{3}
$$

| Name | Kind | Done |
|:-----|:----:|-----:|
| Parser | core | yes |
| UIKit view | new | wip |

"""
