const n = 100000;
const m = {name: "Alice", age: 30, city: "NYC", score: 95, level: 5};
let total = 0;
for (let i = 0; i < n; i++) {
    total += m.score;
}
console.log(total);
