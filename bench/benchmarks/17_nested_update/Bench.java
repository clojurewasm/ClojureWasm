import java.util.HashMap;

public class Bench {
    public static void main(String[] args) {
        int n = 10000;
        // Nested HashMap to mirror Clojure's nested map
        HashMap<String, Object> c = new HashMap<>();
        c.put("c", 0L);
        HashMap<String, Object> b = new HashMap<>();
        b.put("b", c);
        HashMap<String, Object> a = new HashMap<>();
        a.put("a", b);

        for (int i = 0; i < n; i++) {
            @SuppressWarnings("unchecked")
            HashMap<String, Object> inner_b = (HashMap<String, Object>) a.get("a");
            @SuppressWarnings("unchecked")
            HashMap<String, Object> inner_c = (HashMap<String, Object>) inner_b.get("b");
            inner_c.put("c", (long) inner_c.get("c") + 1);
        }

        @SuppressWarnings("unchecked")
        HashMap<String, Object> rb = (HashMap<String, Object>) a.get("a");
        @SuppressWarnings("unchecked")
        HashMap<String, Object> rc = (HashMap<String, Object>) rb.get("b");
        System.out.println(rc.get("c"));
    }
}
