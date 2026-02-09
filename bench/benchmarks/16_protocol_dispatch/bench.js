class Computable {
    constructor(factor) {
        this.factor = factor;
    }
    compute(x) {
        return this.factor * x;
    }
}

const n = 10000;
const m = new Computable(3);
let total = 0;
for (let i = 0; i < n; i++) {
    total += m.compute(i);
}
console.log(total);
