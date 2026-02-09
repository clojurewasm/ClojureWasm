const n = 1000;
const m = new Map();
for (let i = 0; i < n; i++) {
    m.set(i, i);
}
let s = 0;
for (let i = 0; i < n; i++) {
    s += m.get(i);
}
console.log(s);
