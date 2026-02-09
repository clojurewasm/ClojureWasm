const n = 10000;
const records = [];
for (let i = 0; i < n; i++) {
    records.push({id: i, value: i * 2, active: i % 3 === 0});
}
let total = 0;
for (const r of records) {
    if (r.active) total += r.value;
}
console.log(total);
