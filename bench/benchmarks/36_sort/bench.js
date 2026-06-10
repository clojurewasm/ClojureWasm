let total = 0;
for (let it = 0; it < 5; it++) {
  const v = [];
  for (let i = 5000; i >= 1; i--) v.push(i);
  v.sort((a, b) => a - b);
  total = 0;
  for (let i = 0; i < 100; i++) total += v[i];
}
console.log(total);
