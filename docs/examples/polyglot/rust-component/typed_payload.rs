wit_bindgen::generate!({ path: "wit", world: "typed-test" });

struct Component;

impl Guest for Component {
    fn process(input: Payload) -> Result<Payload, String> {
        if input.label == "fail" {
            return Err(format!("boom: {}", input.label));
        }
        let mut xs = input.xs;
        xs.push(xs.iter().sum());
        Ok(Payload { xs, label: format!("{}!", input.label) })
    }
}

export!(Component);
