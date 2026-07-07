---
name: briefing-management
description: Use when creating or updating recurring briefings (daily/weekly). Ensures briefings are generic, structured, and informative.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [briefing, cron, productivity]
    related_skills: []
---

# Briefing Management

## Overview
Standardizes the structure and naming of recurring daily/weekly briefings to ensure they are generic, informative, and follow user preferences.

## Standard Structure (Daily Briefing)
1. **AI & Technology**: Top 2-3 key headlines with markdown links to sources.
2. **Global Finance**: Top 2-3 key headlines with markdown links to sources.
3. **US Market Movers & Indices**: 
   - Index-level changes (S&P 500, Nasdaq, Dow).
   - Top 2-3 specific stock gainers/losers with percentage changes and brief reasons.
   - Omit section if the US market was closed.

## Standard Structure (Weekly Briefing)
1. **Top Tech/AI News**: Concise summary of the week's key developments.
2. **HDB Sale of Balance Flats (SBF)**: Any news/updates regarding upcoming exercises.

## Guidelines
- **Naming**: Use generic titles like "Daily Briefing" or "Weekly Briefing".
- **Tone**: Concise and direct.
- **Sources**: Always include direct markdown links to the source articles.
- **Error Prevention**: If the brief involves complex tasks or external APIs, pin the model to a stable one if drift causes failure, or design prompts to be resilient (e.g., explicit instruction to ignore sections if data is unavailable).

## Common Pitfalls
- **Truncation**: If a briefing is too detailed, it will be truncated by the output limit. Keep summaries concise.
- **Drift**: If global inference configuration changes, cron jobs might fail. Pin the job model if it becomes unstable.
- **Market Status**: Always ensure logic accounts for market closures (weekends/holidays).

## Verification Checklist
- [ ] Briefing is genericly named.
- [ ] Direct source links included.
- [ ] Structured by categories.
- [ ] US Market Movers section respects trading days.
