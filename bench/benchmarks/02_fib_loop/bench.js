let a = 0, b = 1;
for (let i = 0; i < 25; i++) {
    const t = a + b;
    a = b;
    b = t;
}
console.log(a);
