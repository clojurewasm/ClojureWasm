function largeHeap(n) {
    const data = [];
    for (let i = 0; i < n; i++) {
        data.push({id: i, val: i + 1});
    }
    let sum = 0;
    for (const m of data) {
        sum += m.val;
    }
    return sum;
}
console.log(largeHeap(100000));
