let total = 0;
let count = 0;
let i = 0;
while (count < 10000) {
    const v = i * 3;
    if (v % 2 === 0) {
        total += v;
        count++;
    }
    i++;
}
console.log(total);
