//
//  MarkdownEngine.swift
//  MarkdownEngine
//
//  Thin re-exporting wrapper around MarkdownEngineCore.
//
//  This module exists so SwiftPM can ship a dynamic `MarkdownEngine`
//  product whose target name differs from the underlying source target
//  (which other in-package targets depend on statically). Consumers
//  `import MarkdownEngine` exactly as before.
//

@_exported import MarkdownEngineCore
