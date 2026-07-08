# MetaTrader 5 and 4 Tools

Open-source tools, indicators, scripts, and Expert Advisor snippets for MetaTrader 5, focused on trading automation, MQL5 development, backtesting workflows, and practical algorithmic trading education.

> ⚠️ Note: MT4 content is not actively maintained. The main focus of this repository is MetaTrader 5 and MQL5.

## Project Purpose

This repository is intended to become a practical learning and development toolkit for traders, students, and developers who want to understand how MetaTrader 5 tools are structured.

The project includes resources related to:

- MQL5 indicators
- Expert Advisor snippets
- Trade management tools
- Currency strength analysis
- Pivot point tools
- Scripts and utilities
- Backtesting-related workflows
- Python and MetaTrader integration experiments
- SQL/database-based trading research utilities

The goal is to make these resources easier to study, test, improve, and reuse in real algorithmic trading development workflows.

## Maintainer Note

This repository is based on an existing open-source fork. My current work is focused on improving the project by organizing the codebase, documenting the tools, adding clearer usage examples, reviewing MQL5 code, and developing new educational resources around MetaTrader 5 automation.

The objective is to gradually turn this repository into a cleaner, more accessible, and more contributor-friendly resource for the MQL5 and algorithmic trading community.

## Main Areas

### Trade Management

Tools and snippets related to order handling, trade management, risk control, basket management, and manual/semi-automated execution workflows.

### Indicators

A collection of MetaTrader 5 indicators and utilities for technical analysis, charting, currency strength, pivots, moving averages, volatility, volume, and market structure.

### Expert Advisor Snippets

Reusable MQL5 examples and code fragments that can help developers understand Expert Advisor structure, entry logic, order management, and testing workflows.

### Backtesting and Research

Resources intended to support faster testing, strategy research, and structured experimentation inside MetaTrader 5.

### Python / SQL / Data Tools

Experimental resources related to Python integration, SQL databases, and data workflows for trading research.

## Repository Structure

| Folder / Area | Description |
|---|---|
| `Trade Manager` | Tools related to trade execution and trade management |
| `Currency Index` | Currency strength and currency index analysis tools |
| `Pivots` | Pivot point indicators and related resources |
| `EA Snippets` | Expert Advisor examples and reusable MQL5 code snippets |
| `Scripts` | Utility scripts for MetaTrader workflows |
| `Include` | Shared MQL5 include files |
| `Libraries` | Supporting libraries and reusable components |
| `Machine Learning` | Experimental machine learning and trading research resources |
| `Mql5-Python-Integration-main` | Python and MetaTrader integration experiments |
| `SQL Server` / `R SQL Server` | Database-oriented research and analysis resources |

## Installation

Most files are intended to be used inside the MetaTrader 5 data folder.

General installation workflow:

1. Open MetaTrader 5.
2. Go to `File > Open Data Folder`.
3. Open the `MQL5` folder.
4. Copy the files into the correct folder:
   - Indicators: `MQL5/Indicators`
   - Expert Advisors: `MQL5/Experts`
   - Scripts: `MQL5/Scripts`
   - Include files: `MQL5/Include`
   - Libraries: `MQL5/Libraries`
5. Restart MetaTrader 5 or refresh the Navigator panel.
6. Compile the `.mq5` files in MetaEditor before using them.

## Usage

This repository is mainly designed for learning, testing, and development.

Recommended workflow:

1. Start with a demo account.
2. Open the relevant `.mq5` file in MetaEditor.
3. Read the input parameters and comments.
4. Compile the file.
5. Test the tool on historical data or in the Strategy Tester.
6. Validate behavior before using any tool in a live environment.

## Roadmap

Planned improvements:

- [ ] Improve README and project documentation
- [ ] Add individual documentation for the main tools
- [ ] Add screenshots and usage examples
- [ ] Organize folders by category
- [ ] Identify maintained vs experimental tools
- [ ] Add setup guides for beginners
- [ ] Add code comments to important MQL5 files
- [ ] Add examples for indicator usage
- [ ] Add examples for Expert Advisor snippets
- [ ] Review and refactor selected MQL5 tools
- [ ] Add testing notes for Strategy Tester workflows
- [ ] Improve Python / MetaTrader integration documentation

## Contributing

Contributions are welcome.

Useful contributions include:

- Documentation improvements
- Bug reports
- Code refactoring
- MQL5 examples
- Installation guides
- Screenshots or usage examples
- Testing notes
- Strategy Tester workflow improvements

Before submitting a pull request, please make sure the code compiles in MetaEditor and include a short explanation of what was changed.

## Disclaimer

This repository is for educational and development purposes only.

Nothing in this repository is financial advice. Trading involves risk, and all tools, indicators, scripts, and Expert Advisor snippets should be tested carefully on demo accounts and historical data before any live use.

No profitability is guaranteed.
