import XCTest
@testable import Folmi

final class ConfigHighlightingTests: XCTestCase {
    func testLanguagesByNameAndExtension() {
        let cases: [(String, SyntaxLanguage)] = [
            (".github/workflows/ci.yml", .yaml), ("docker-compose.yaml", .yaml), ("Cargo.toml", .toml), ("Cargo.lock", .toml),
            ("pyproject.toml", .toml), ("setup.cfg", .ini), (".editorconfig", .ini), (".gitconfig", .ini), ("app.ini", .ini),
            (".env", .dotenv), (".env.local", .dotenv), ("prod.env", .dotenv), (".gitignore", .ignore), (".dockerignore", .ignore),
            ("Dockerfile", .dockerfile), ("api/Dockerfile.dev", .dockerfile), ("web.dockerfile", .dockerfile),
            ("Makefile", .makefile), ("rules.mk", .makefile), ("Info.plist", .xml), ("index.html", .xml), ("pom.xml", .xml),
            ("style.css", .css), ("theme.scss", .css), ("schema.sql", .sql), (".zshrc", .shell), (".prettierrc", .json),
            ("tsconfig.json", .json), ("notes.unknown", .plainText)
        ]
        for (path, language) in cases { XCTAssertEqual(SyntaxLanguage(path: path), language, path) }
    }

    func testYAMLKeysScalarsCommentsAndBlockText() throws {
        let text = """
        # CI
        name: build
        on:
          push:
            branches: [main, "release/*"]
        jobs:
          test:
            runs-on: ubuntu-latest
            timeout: 30 # minutes
            enabled: true
            steps:
              - uses: actions/checkout@v4
              - run: |
                  echo key: not-a-key
                  # not a comment
            base: &base
            url: http://x.io:80/a
        """
        let r = try tokens(text, .yaml)
        XCTAssertEqual(r[.variable], ["name", "on", "push", "branches", "jobs", "test", "runs-on", "timeout", "enabled", "steps", "uses", "run", "base", "url"])
        XCTAssertEqual(r[.comment], ["# CI", "# minutes"])
        XCTAssertEqual(r[.string], ["\"release/*\""])
        XCTAssertEqual(r[.number], ["30"])
        XCTAssertEqual(r[.literal], ["true"])
        XCTAssertEqual(r[.keyword], ["|"])
        XCTAssertEqual(r[.type], ["&base"])
    }

    func testTOMLTablesKeysMultilineStringsAndArrays() throws {
        let text = """
        [package]
        name = "demo" # crate
        version = "0.1.0"
        edition = 2021
        publish = false
        description = \"\"\"
        two = "lines"
        \"\"\"
        [dependencies]
        serde = { version = "1", features = ["derive"] }
        list = [
          1, 2,
        ]
        when = 1979-05-27T07:32:00Z
        """
        let r = try tokens(text, .toml)
        XCTAssertEqual(r[.type], ["[package]", "[dependencies]"])
        XCTAssertEqual(r[.variable], ["name", "version", "edition", "publish", "description", "serde", "version", "features", "list", "when"])
        XCTAssertEqual(r[.comment], ["# crate"])
        XCTAssertEqual(r[.literal], ["false"])
        XCTAssertEqual(r[.number], ["2021", "1", "2", "1979-05-27T07:32:00Z"])
        XCTAssertTrue(r[.string]?.contains("two = \"lines\"") == true)
    }

    func testINIEnvAndIgnoreFiles() throws {
        let ini = "; top\n[core]\n\tautocrlf = input\n[remote \"origin\"]\nurl = https://x.io/a.git # remote\nroot = true\nindent_size = 4\n"
        let i = try tokens(ini, .ini)
        XCTAssertEqual(i[.type], ["[core]", "[remote \"origin\"]"])
        XCTAssertEqual(i[.variable], ["autocrlf", "url", "root", "indent_size"])
        XCTAssertEqual(i[.comment], ["; top", "# remote"])
        XCTAssertEqual(i[.literal], ["true"])
        XCTAssertEqual(i[.number], ["4"])

        let env = "# keys\nexport API_URL=https://x.io/${REGION}/v1\nSECRET=\"a b#c\" # quoted\nPORT=8080\n"
        let e = try tokens(env, .dotenv)
        XCTAssertEqual(e[.keyword], ["export"])
        XCTAssertEqual(e[.variable], ["API_URL", "${REGION}", "SECRET", "PORT"])
        XCTAssertEqual(e[.string], ["\"a b#c\""])
        XCTAssertEqual(e[.comment], ["# keys", "# quoted"])

        let ignore = "# build\n.build/\n!keep.log\n*.o\n"
        let g = try tokens(ignore, .ignore)
        XCTAssertEqual(g[.comment], ["# build"])
        XCTAssertEqual(g[.keyword], ["!"])
    }

    func testDockerfileInstructionsStagesAndContinuations() throws {
        let text = """
        # syntax
        FROM node:20 AS build
        ARG MODE=prod
        RUN npm ci && \\
            run build --mode $MODE
        COPY --from=build /app/dist "/srv/my site"
        """
        let r = try tokens(text, .dockerfile)
        XCTAssertEqual(r[.keyword], ["FROM", "AS", "ARG", "RUN", "COPY"])
        XCTAssertEqual(r[.comment], ["# syntax"])
        XCTAssertEqual(r[.variable], ["$MODE"])
        XCTAssertEqual(r[.type], ["--mode", "--from"])
        XCTAssertEqual(r[.string], ["\"/srv/my site\""])
    }

    func testMakefileTargetsAssignmentsAndRecipes() throws {
        let text = "CC ?= clang\nSRC := $(wildcard src/*.c) # sources\n.PHONY: all\nall: build $(SRC)\n\t@echo \"done $@\"\nifeq ($(OS),Darwin)\nendif\n"
        let r = try tokens(text, .makefile)
        XCTAssertEqual(r[.variable], ["CC", "SRC", "$(wildcard src/*.c)", "$(SRC)", "$(OS)"])
        XCTAssertEqual(r[.comment], ["# sources"])
        XCTAssertEqual(r[.keyword], [".PHONY", "ifeq", "endif"])
        XCTAssertEqual(r[.type], ["all"])
        XCTAssertEqual(r[.string], ["\"done $@\""])
    }

    func testXMLTagsAttributesCommentsAcrossLines() throws {
        let text = """
        <?xml version="1.0"?>
        <!-- one
        two -->
        <plist version="1.0">
          <key>Name</key>
          <img src="a.png"
               alt="x &amp; y"/>
          <![CDATA[ <b> ]]> 1 &lt; 2
        </plist>
        """
        let r = try tokens(text, .xml)
        XCTAssertEqual(r[.keyword], ["<?xml", "plist", "key", "key", "img", "plist"])
        XCTAssertEqual(r[.variable], ["version", "version", "src", "alt"])
        XCTAssertEqual(r[.comment], ["<!-- one", "two -->"])
        XCTAssertEqual(r[.string], ["\"1.0\"", "\"1.0\"", "\"a.png\"", "\"x &amp; y\"", "<![CDATA[ <b> ]]>"])
        XCTAssertEqual(r[.literal], ["&lt;"])
    }

    func testCSSSelectorsPropertiesNumbersAndVariables() throws {
        let text = """
        /* theme */
        :root { --accent: #3a7bd5; }
        @media (max-width: 600px) {
          .card h1, .card:hover {
            margin: -1.5em 0 .5rem;
            color: var(--accent) !important;
            width: 50%;
          }
        }
        """
        let r = try tokens(text, .css)
        XCTAssertEqual(r[.comment], ["/* theme */"])
        XCTAssertEqual(r[.type], [":root", ".card h1, .card:hover"])
        XCTAssertEqual(r[.keyword], ["@media", "!important"])
        XCTAssertEqual(r[.variable], ["--accent", "margin", "color", "--accent", "width"])
        XCTAssertEqual(r[.number], ["#3a7bd5", "600px", "-1.5em", "0", ".5rem", "50%"])
    }

    func testSQLKeywordsTypesStringsAndComments() throws {
        let text = "-- users\nCREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT DEFAULT 'it''s', v2 int);\nselect * from users where id = :id and name is not null limit 10; /* end */"
        let r = try tokens(text, .sql)
        XCTAssertEqual(r[.comment], ["-- users", "/* end */"])
        XCTAssertEqual(r[.keyword], ["CREATE", "TABLE", "PRIMARY", "KEY", "DEFAULT", "select", "from", "where", "and", "is", "not", "limit"])
        XCTAssertEqual(r[.type], ["INTEGER", "TEXT", "int"])
        XCTAssertEqual(r[.string], ["'it''s'"])
        XCTAssertEqual(r[.variable], [":id"])
        XCTAssertEqual(r[.literal], ["null"])
        XCTAssertEqual(r[.number], ["10"])
    }

    func testConfigScannerHonoursLimitsAndCancellation() throws {
        let yaml = String(repeating: "key: value # c\n", count: 1_000)
        let limited = try XCTUnwrap(SyntaxTokenizer.tokenize(yaml, language: .yaml, maximumTokens: 30))
        XCTAssertTrue(limited.isLimited)
        XCTAssertLessThanOrEqual(limited.tokens.count, 30)
        XCTAssertNil(SyntaxTokenizer.tokenize(yaml, language: .yaml, isCancelled: { true }))
        XCTAssertNil(SyntaxTokenizer.tokenize(String(repeating: "a { b: 1 }\n", count: 1_000), language: .css, isCancelled: { true }))
        let cut = try XCTUnwrap(SyntaxTokenizer.tokenize(yaml, language: .yaml, maximumUTF16Count: 100))
        XCTAssertTrue(cut.isLimited)
        XCTAssertLessThanOrEqual(cut.scannedUTF16Count, 100)
    }

    func testEveryLanguageGivesOrderedNonOverlappingRanges() throws {
        let samples: [(SyntaxLanguage, String)] = [
            (.yaml, "a: 'x''y' # 😀\n- [1, {b: c}]\nk: >-\n  text: 1\n"), (.toml, "a.b = '''x\ny''' # c\n[t]\nx = [\"a\", 1.5e3]"),
            (.ini, "[s]\nk: v ; c"), (.dotenv, "A=${B}$C\"d\" # e"), (.dockerfile, "RUN a \\\n  RUN b"), (.makefile, "a: b ; c\n\tx $(y\n"),
            (.xml, "<a b='c' d=\"e\n<!-- f"), (.css, "a{b:\"c\";d:1px} /* x"), (.sql, "select 'a\nb' -- c\n/* d")
        ]
        for (language, text) in samples {
            let result = try XCTUnwrap(SyntaxTokenizer.tokenize(text, language: language))
            var previous = 0
            for token in result.tokens {
                XCTAssertGreaterThanOrEqual(token.range.location, previous, "\(language)")
                XCTAssertGreaterThan(token.range.length, 0, "\(language)")
                XCTAssertLessThanOrEqual(NSMaxRange(token.range), text.utf16.count, "\(language)")
                previous = NSMaxRange(token.range)
            }
        }
    }

    func testMarkdownCodeFencesUseTheNewLanguages() {
        XCTAssertEqual(MarkdownCodeHighlight.language("yaml"), .yaml)
        XCTAssertEqual(MarkdownCodeHighlight.language("yml"), .yaml)
        XCTAssertEqual(MarkdownCodeHighlight.language("Dockerfile"), .dockerfile)
        XCTAssertEqual(MarkdownCodeHighlight.language("dotenv"), .dotenv)
        XCTAssertEqual(MarkdownCodeHighlight.language("html"), .xml)
        XCTAssertEqual(MarkdownCodeHighlight.language("sql"), .sql)
        XCTAssertEqual(MarkdownCodeHighlight.language("toml"), .toml)
        XCTAssertTrue(MarkdownCodeHighlight.html("name: x", language: "yaml").contains("tok-variable"))
    }

    private func tokens(_ text: String, _ language: SyntaxLanguage) throws -> [SyntaxTokenKind: [String]] {
        let result = try XCTUnwrap(SyntaxTokenizer.tokenize(text, language: language))
        var out: [SyntaxTokenKind: [String]] = [:]
        for token in result.tokens { out[token.kind, default: []].append((text as NSString).substring(with: token.range)) }
        return out
    }
}

final class ConfigHighlightingEdgeTests: XCTestCase {
    private func tokens(_ text: String, _ language: SyntaxLanguage) throws -> [SyntaxTokenKind: [String]] {
        let result = try XCTUnwrap(SyntaxTokenizer.tokenize(text, language: language))
        var out: [SyntaxTokenKind: [String]] = [:]
        for token in result.tokens { out[token.kind, default: []].append((text as NSString).substring(with: token.range)) }
        return out
    }

    func testYAMLQuotedScalarsAndFlowCollectionsSpanLines() throws {
        let text = """
        message: "first line
          second: not a key"
        tags: [
          alpha, 2,
          true
        ]
        after: 3
        quote: 'it''s
          fine'
        """
        let r = try tokens(text, .yaml)
        XCTAssertEqual(r[.variable], ["message", "tags", "after", "quote"])
        XCTAssertEqual(r[.string], ["\"first line", "  second: not a key\"", "'it''s", "  fine'"])
        XCTAssertEqual(r[.number], ["2", "3"])
        XCTAssertEqual(r[.literal], ["true"])
    }

    func testTOMLMultilineStringsKeepEscapedQuotes() throws {
        let text = #"""
        text = """
        he said \"""hi\""" here
        """
        next = 1
        raw = '''a "" b'''
        """#
        let r = try tokens(text, .toml)
        XCTAssertEqual(r[.variable], ["text", "next", "raw"])
        XCTAssertEqual(r[.number], ["1"])
        XCTAssertEqual(r[.string]?.count, 4)
        XCTAssertEqual(r[.string]?.last, #"'''a "" b'''"#)
    }
}
