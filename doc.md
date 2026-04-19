---
title: My Report
subtitle: Markdown to PDF with Nix
author:
  - Reza Rajan
date: 2026-04-19
---

# Overview

This is a simple report.

## Long table

| Column A | Column B | Column C |
|---|---|---|
| A very long row that should wrap properly across pages if needed | More content | Even more content |
| Another long row | More text | More text |

## Mermaid

```mermaid
flowchart TD
    A[Markdown] --> B[Python preprocessor]
    B --> C[Mermaid SVG]
    C --> D[Pandoc]
    D --> E[PDF]
```
