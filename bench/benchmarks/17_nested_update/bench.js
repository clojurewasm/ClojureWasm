const n = 10000;
const m = {a: {b: {c: 0}}};
for (let i = 0; i < n; i++) {
    m.a.b.c += 1;
}
console.log(m.a.b.c);
