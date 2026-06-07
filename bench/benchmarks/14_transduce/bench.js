const n = 10000;
let total = 0;
for (let i = 0; i < n; i++) {
    const v = i * 3;
    if (v % 2 === 0) {
        total += v;
    }
}
console.log(total);
