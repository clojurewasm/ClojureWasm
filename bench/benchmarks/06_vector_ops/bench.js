const n = 10000;
const vec = [];
for (let i = 0; i < n; i++) {
    vec.push(i);
}
let s = 0;
for (let i = 0; i < n; i++) {
    s += vec[i];
}
console.log(s);
