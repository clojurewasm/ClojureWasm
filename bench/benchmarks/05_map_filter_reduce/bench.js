const xs = Array.from({length: 10000}, (_, i) => i);
const mapped = xs.map(x => x * x);
const filtered = mapped.filter(x => x % 2 === 0);
const result = filtered.reduce((a, b) => a + b, 0);
console.log(result);
