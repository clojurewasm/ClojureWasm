import java.util.HashMap;

public class Bench {
    static long process(HashMap<String, Object> data) {
        String type = (String) data.get("type");
        long a = (long) data.get("a");
        long b = (long) data.get("b");
        switch (type) {
            case "add": return a + b;
            case "mul": return a * b;
            case "sub": return a - b;
            default: return 0;
        }
    }

    public static void main(String[] args) {
        int n = 10000;
        HashMap<String, Object> data = new HashMap<>();
        data.put("type", "add");
        data.put("a", 3L);
        data.put("b", 4L);
        long sum = 0;
        for (int i = 0; i < n; i++) {
            sum += process(data);
        }
        System.out.println(sum);
    }
}
