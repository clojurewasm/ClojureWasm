const n = 100000;
let total = 0;
for (let i = 0; i < n; i++) {
    total += String(i).length;
}
console.log(total);
