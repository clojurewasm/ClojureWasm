import java.util.LinkedList;

public class Bench {
    public static void main(String[] args) {
        int n = 10000;
        LinkedList<Long> list = new LinkedList<>();
        for (int i = 0; i < n; i++) list.addFirst((long) i);
        System.out.println(list.size());
    }
}
