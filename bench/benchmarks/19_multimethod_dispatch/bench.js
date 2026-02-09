function process(data) {
    switch (data.type) {
        case "add": return data.a + data.b;
        case "mul": return data.a * data.b;
        case "sub": return data.a - data.b;
    }
}

const n = 10000;
const data = {type: "add", a: 3, b: 4};
let total = 0;
for (let i = 0; i < n; i++) {
    total += process(data);
}
console.log(total);
