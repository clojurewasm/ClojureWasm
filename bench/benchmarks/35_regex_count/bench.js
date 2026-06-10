const s = "a12b345c6789d0e";
let c = 0;
for (let i = 0; i < 10000; i++) c = (s.match(/\d+/g) || []).length;
console.log(c);
