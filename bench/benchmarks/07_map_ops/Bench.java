import java.util.HashMap;

public class Bench {
    public static void main(String[] args) {
        int n = 1000;
        HashMap<Integer, Integer> map = new HashMap<>();
        for (int i = 0; i < n; i++) map.put(i, i);

        long sum = 0;
        for (int i = 0; i < n; i++) sum += map.get(i);

        System.out.println(sum);
    }
}
