import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class Bench {
    public static void main(String[] args) {
        Pattern p = Pattern.compile("\\d+");
        String s = "a12b345c6789d0e";
        int c = 0;
        for (int i = 0; i < 10000; i++) {
            Matcher m = p.matcher(s);
            c = 0;
            while (m.find()) c++;
        }
        System.out.println(c);
    }
}
