import java.util.HashMap;

public class Bench {
    public static void main(String[] args) {
        int n = 100000;
        long sum = 0;
        for (int i = 0; i < n; i++) {
            HashMap<String, Long> m = new HashMap<>();
            m.put("a", (long) i);
            m.put("b", (long) (i + 1));
            m.put("c", (long) (i + 2));
            sum += m.get("b");
        }
        System.out.println(sum);
    }
}
