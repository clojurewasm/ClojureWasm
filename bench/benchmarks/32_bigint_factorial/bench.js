let f = 1n;
for (let i = 0; i < 1000; i++) {
  f = 1n;
  for (let k = 2n; k <= 100n; k++) f *= k;
}
console.log(f.toString().length);
