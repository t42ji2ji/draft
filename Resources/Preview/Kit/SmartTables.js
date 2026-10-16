// Spreadsheet-style formulas in preview tables. A cell whose whole text is =(expression) shows the
// result instead. Cells are named like a spreadsheet: columns A, B, … and rows counted from 0, so in a
// table with one header row the first body row is 1. =(TOTAL) sums the body cells above it in its column.
// Expressions go to math.js; plain cells are read as numbers with numeral.js ("1,200", "$5", "12%").
window.SmartTables = (() => {
  const FORMULA = /^=\(([\s\S]*)\)$/;
  const REFERENCE = /\b[A-Z]+\d+\b/gi;

  const columnName = (i) => (i >= 26 ? columnName(Math.floor(i / 26) - 1) : '') + String.fromCharCode(65 + (i % 26));
  const formulaOf = (cell) => FORMULA.exec(cell.textContent.trim())?.[1].trim();

  function processTable(table) {
    // name -> {cell, row, col}
    const cells = new Map();
    [...table.rows].forEach((tr, row) => [...tr.cells].forEach((cell, col) => {
      cells.set(columnName(col) + row, { cell, row, col });
    }));
    const formulas = [...cells.keys()].filter((name) => formulaOf(cells.get(name).cell) !== undefined);
    if (!formulas.length) return;

    // Values are worked out on demand and remembered; NaN marks an error, including circular references.
    const values = new Map();
    const value = (name) => {
      if (!values.has(name)) {
        values.set(name, NaN);
        values.set(name, compute(cells.get(name)));
      }
      return values.get(name);
    };

    function compute({ cell, row, col }) {
      const formula = formulaOf(cell);
      if (formula === undefined) {
        const text = cell.textContent.trim();
        return text ? numeral(text).value() ?? NaN : 0;
      }
      if (formula.toUpperCase() === 'TOTAL') {
        let sum = 0;
        for (let r = 0; r < row; r++) {
          const above = cells.get(columnName(col) + r);
          if (above && above.cell.parentElement.parentElement.tagName !== 'THEAD') sum += value(columnName(col) + r);
        }
        return sum;
      }
      try {
        const expression = formula.replace(REFERENCE, (ref) => (cells.has(ref.toUpperCase()) ? `(${value(ref.toUpperCase())})` : ref));
        return Number(math.evaluate(expression));
      } catch {
        return NaN;
      }
    }

    // Work everything out before writing, since writing replaces the formulas other cells read.
    const results = formulas.map((name) => [cells.get(name).cell, value(name)]);
    for (const [cell, result] of results) {
      if (Number.isFinite(result)) {
        // toPrecision trims float noise such as 0.1 + 0.2 = 0.30000000000000004.
        cell.textContent = math.format(Number(result.toPrecision(15)), { notation: 'fixed' });
      } else {
        cell.innerHTML = '<span style="color: red">#ERR</span>';
      }
    }
  }

  return { processTable };
})();
