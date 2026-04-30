use dnf_generator::generate::Generate;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let command = args.get(1).map(String::as_str).unwrap_or("?");
    let debug = args.get(2).map(String::as_str) == Some("debug");

    let project_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("Cannot determine project root");

    let main_yaml = project_root.join("usr/config.yaml");
    let generated_yaml = project_root.join("var/generated/config.yaml");

    match Generate::new(&main_yaml, &generated_yaml) {
        Ok(generator) => match generator.run(command) {
            Ok(output) => print!("{output}"),
            Err(e) => {
                eprintln!("ERR: {e}");
                if debug {
                    eprintln!("{e:?}");
                }
                std::process::exit(1);
            }
        },
        Err(e) => {
            eprintln!("ERR: {e}");
            if debug {
                eprintln!("{e:?}");
            }
            std::process::exit(1);
        }
    }
}
