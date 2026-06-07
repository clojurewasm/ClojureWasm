class Node {
    constructor(val, next) {
        this.val = val;
        this.next = next || null;
    }
}

const n = 10000;
let head = null;
for (let i = 0; i < n; i++) {
    head = new Node(i, head);
}

let count = 0;
let cur = head;
while (cur !== null) {
    count++;
    cur = cur.next;
}
console.log(count);
