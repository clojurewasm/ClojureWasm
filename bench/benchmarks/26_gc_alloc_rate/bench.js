function allocRate(n) {
    let sum = 0;
    for (let i = 0; i < n; i++) {
        const v = [i, i + 1, i + 2, i + 3];
        sum += v[2];
    }
    return sum;
}
console.log(allocRate(200000));
