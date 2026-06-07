import java.util.ArrayList;
import java.util.HashMap;

public class Bench {
    public static void main(String[] args) {
        int n = 10000;
        ArrayList<HashMap<String, Object>> records = new ArrayList<>();
        for (int i = 0; i < n; i++) {
            HashMap<String, Object> r = new HashMap<>();
            r.put("id", i);
            r.put("value", (long) i * 2);
            r.put("active", i % 3 == 0);
            records.add(r);
        }

        long sum = 0;
        for (HashMap<String, Object> r : records) {
            if ((boolean) r.get("active")) {
                sum += (long) r.get("value");
            }
        }
        System.out.println(sum);
    }
}
