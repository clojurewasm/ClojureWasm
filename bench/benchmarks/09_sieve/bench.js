function sieve(limit) {
    let candidates = [];
    for (let i = 2; i <= limit; i++) candidates.push(i);
    let count = 0;
    while (candidates.length > 0) {
        const p = candidates[0];
        count++;
        candidates = candidates.slice(1).filter(x => x % p !== 0);
    }
    return count;
}
console.log(sieve(1000));
