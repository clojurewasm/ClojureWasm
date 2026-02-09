const n = 100000;
let total = 0;
for (let i = 0; i < n; i++) {
    const m = {a: i, b: i + 1, c: i + 2};
    total += m.b;
}
console.log(total);
