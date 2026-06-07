import java.util.HashMap;

public class Bench {
    public static void main(String[] args) {
        int n = 100000;
        HashMap<String, Object> m = new HashMap<>();
        m.put("name", "Alice");
        m.put("age", 30);
        m.put("city", "NYC");
        m.put("score", 95);
        m.put("level", 5);
        long sum = 0;
        for (int i = 0; i < n; i++) {
            sum += (int) m.get("score");
        }
        System.out.println(sum);
    }
}
