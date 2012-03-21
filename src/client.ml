open ExtList
open Namespace
open Path
open Server
open Solver

let log fmt =
  Globals.log "CLIENT" fmt

module type CLIENT =
sig
  type t

  (** Initializes the client a consistent state. *)
  val init : url -> unit

  (** Displays the installed package. [None] : a general summary is given. *)
  val info : Namespace.name option -> unit

  type config_request = Dir | Bytelink | Asmlink

  (** Depending on request, returns options or directories where the package is installed. *)
  val config : bool (* true : recursive search *) -> config_request -> Namespace.name -> unit

  (** Installs the given package. *)
  val install : Namespace.name -> unit

  (** Downloads the latest packages available. *)
  val update : unit -> unit

  (** Finds a consistent state where most of the installed packages are
      upgraded to their latest version. *)
  val upgrade : unit -> unit

  (** Sends a new created package to the server. *)
  val upload : string -> unit

  (** Removes the given package. *)
  val remove : Namespace.name -> unit
end

module Client : CLIENT = struct
  open File

  type t = 
      { server : url
      ; home   : Path.t (* ~/.opam *) }


  (* Look into the content of ~/.opam/config to build the client state *)
  let load_state () =
    let home = Path.init !Globals.root_path in
    let config = File.Config.find_err (Path.config home) in
    let server = File.Config.sources config in
    if RemoteServer.acceptedVersion server Globals.version then
      { server ;  home }
    else
      begin
        Globals.msg "The version of this program is different than the one at server side.\n";
        exit 1;
      end

  let update_t t =
    let packages = RemoteServer.getList t.server in
    List.iter
      (fun (n, v) -> 
        let opam_file = Path.index_opam t.home (Some (n, v)) in
        if not (Path.file_exists opam_file) then
          let opam = RemoteServer.getOpam t.server (n, v) in
          Path.add opam_file (Path.File opam);
          Globals.msg "New package available: %s" (Namespace.string_of_nv n v)
      ) packages

  let update () =
    update_t (load_state ())

  let init url =
    log "init %s" (string_of_url url);
    let home = Path.init !Globals.root_path in
    let config =
      File.Config.create
        (Version Globals.opam_version)
        url
        (Version Globals.ocaml_version) in
    File.Config.add (Path.config home) config;
    File.Installed.add (Path.installed home) File.Installed.empty;
    update ()

  let indent_left s nb = s ^ String.make nb ' '

  let indent_right s nb = String.make nb ' ' ^ s

  let find_from_name name l = 
    N_map.Exceptionless.find 
      name
      (List.fold_left
         (fun map (n, v) -> 
            N_map.modify_def V_set.empty n (V_set.add v) map) N_map.empty l)

  let info package =
    log "info %s" (match package with
      | None -> "ALL"
      | Some p -> Namespace.string_of_name p);
    let t = load_state () in
    let s_not_installed = "--" in
    match package with
    | None -> 
        (* Get all the installed packages *)
        let installed = File.Installed.find_err (Path.installed t.home) in
        let install_set = NV_set.of_list installed in
        let map, max_n, max_v = 
          List.fold_left
            (fun (map, max_n, max_v) n_v -> 
              let b = NV_set.mem n_v install_set in
              let opam = File.Opam.find_err (Path.index_opam t.home (Some n_v)) in
              let new_map = NV_map.add n_v (b, File.Opam.description opam) map in
              let new_max_n = max max_n (String.length (Namespace.string_user_of_name (fst n_v))) in
              let new_max_v =
                if b then max max_v (String.length (Namespace.string_user_of_version (snd n_v))) else max_v in
            new_map, new_max_n, new_max_v)
            (NV_map.empty, min_int, String.length s_not_installed)
            (Path.index_opam_list t.home) in

        NV_map.iter (fun n_v (b, description) -> 
          Globals.msg "%s %s %s\n" 
            (indent_left (Namespace.string_user_of_name (fst n_v)) max_n)
            (indent_right (if b then Namespace.string_user_of_version (snd n_v) else s_not_installed) max_v)
            description) map;
        Globals.msg "\n"

    | Some name -> 
        let find_from_name = find_from_name name in
        let installed = File.Installed.find_err (Path.installed t.home) in
        let o_v = 
          Option.map
            V_set.choose (* By definition, there is exactly 1 element, we choose it. *) 
            (find_from_name installed) in

        let v_set =
          let v_set = 
            match find_from_name (Path.index_opam_list t.home) with
            | None -> V_set.empty
            | Some v -> v in
          match o_v with
          | None -> v_set
          | Some v -> V_set.remove v v_set in

        List.iter
          (fun (tit, desc) -> Globals.msg "%s: %s\n" tit desc)
          [ "package", Namespace.string_user_of_name name

          ; "version",
            (match o_v with
            | None   -> s_not_installed
            | Some v -> Namespace.string_user_of_version v)

          ; "versions", (V_set.to_string Namespace.string_user_of_version v_set)

          ; "description", "\n" ^ 
            match o_v with None -> ""
            | Some v ->
                let opam =
                  File.Opam.find_err (Path.index_opam t.home (Some (name, v))) in
                File.Opam.description opam
          ]

  let confirm msg = 
    Globals.msg "%s [y/N] " msg;
    match read_line () with
      | "y" | "Y" -> true
      | _         -> false

  let iter_toinstall f_add_rec t (name, v) = 

    let to_install = File.To_install.find_err (Path.to_install t.home (name, v)) in

    let filename_of_path_relative t path = 
      Path.R_filename (File.To_install.filename_of_path_relative t.home
                         (Path.build t.home (Some (name, v))) 
                         path) in
    
    let add_rec f_lib t path = 
      f_add_rec
        (f_lib t.home name (* warning : we assume that this result is a directory *))
        (filename_of_path_relative t path) in

    (* lib *) 
    List.iter (add_rec Path.lib t) (File.To_install.lib to_install);
  
    (* bin *) 
    BatOption.iter (add_rec (fun t _ -> Path.bin t) t) (File.To_install.bin to_install);
  
    (* misc *)
    List.iter 
      (fun misc ->
        Globals.msg "%s\n" (File.To_install.string_of_misc misc);
        if confirm "Continue ?" then
          let path_from =
            filename_of_path_relative t (File.To_install.path_from misc) in
          List.iter 
            (fun path_to -> f_add_rec path_to path_from) 
            (File.To_install.filename_of_path_absolute t.home
               (File.To_install.path_to misc)))
      (File.To_install.misc to_install)

  let proceed_todelete t (n, v0) = 
    File.Installed.modify_def (Path.installed t.home) 
      (fun map_installed -> 
        match N_map.Exceptionless.find n map_installed with
          | Some v when v = v0 ->
            iter_toinstall
              (fun file -> function
                | Path.R_filename l -> 
                  List.iter (fun f -> Path.remove (Path.concat file (Path.basename f))) l
                | _ -> failwith "to complete !")
              t
              (n, v);
            N_map.remove n map_installed
              
          | _ -> map_installed)

  let proceed_torecompile t nv =
    if Path.exec_buildsh t.home nv = 0 then
      iter_toinstall Path.add_rec t nv
    else
      Globals.error_and_exit "./build.sh failed. We stop here because otherwise the installation would fail to copy not created files."

  let delete_or_update l =
    let action = function
      | Solver.To_change(Was_installed _,_ )
      | Solver.To_delete _ -> true
      | _ -> false in
    let parallel (Solver.P l) = List.exists action l in
    List.exists parallel l

  let proceed_tochange t nv_old (name, v) =
    begin match nv_old with 
      | Was_installed nv_old -> proceed_todelete t nv_old
      | Was_not_installed ->
          let p_build = Path.build t.home (Some (name, v)) in
          if Path.file_exists p_build then
            ()
          else
            let tgz = Path.extract_targz (RemoteServer.getArchive t.server (name, v)) in
            Path.add_rec p_build tgz
    end;
    proceed_torecompile t (name, v);
    File.Installed.modify_def (Path.installed t.home) (N_map.add name v)

  let debpkg_of_nv t map_installed =
    List.fold_left
      (fun l n_v ->
        let opam = File.Opam.find_err (Path.index_opam t.home (Some n_v)) in
        let pkg = 
          File.Opam.package opam
            (match N_map.Exceptionless.find (fst n_v) map_installed with
              | Some v -> v = snd n_v
              | _ -> false) in
        pkg :: l) 
      []

  let resolve t l_index map_installed request = 
    
    let l_pkg = debpkg_of_nv t map_installed l_index in

    match Solver.resolve_list l_pkg request with
    | [] -> Globals.msg "No solution has been found.\n"
    | l -> 
      let nb_sol = List.length l in

      let rec aux pos = 
        Globals.msg "{%d/%d} The following solution has been found:\n" pos nb_sol;
        function
      | [x] ->
          (* Only 1 solution exists *)
          Solver.solution_print Namespace.string_of_user x;
          if delete_or_update x then
            if confirm "Continue ?" then
              Some x
            else
              None
          else
            Some x

      | x :: xs ->
          (* Multiple solution exist *)
          Solver.solution_print Namespace.string_of_user x;
          if delete_or_update x then
            if confirm "Continue ? (press [n] to try another solution)" then
              Some x
            else
              aux (succ pos) xs
          else
            Some x

      | [] -> assert false in

        match aux 1 l with
          | Some sol -> 
            List.iter (fun(Solver.P l) -> 
              List.iter (function
                | Solver.To_change (o,n)  -> proceed_tochange t o n
                | Solver.To_delete n_v    -> proceed_todelete t n_v
                | Solver.To_recompile n_v -> proceed_torecompile t n_v
              ) l
            ) sol
          | None -> ()

  let vpkg_of_nv (name, v) = Namespace.string_of_name name, Some ("=", v.Namespace.deb)

  let unknown_package name =
    Globals.error_and_exit
      "ERROR: Unable to locate package \"%s\"\n"
      (Namespace.string_user_of_name  name)

  let install name = 
    log "install %s" (Namespace.string_of_name name);
    let t = load_state () in
    let l_index = Path.index_opam_list t.home in
    match find_from_name name l_index with
      | None -> unknown_package name
      | Some v -> 
        let map_installed = File.Installed.find_map (Path.installed t.home) in
        resolve t
          l_index
          map_installed
          [ { Solver.wish_install = 
              List.map vpkg_of_nv ((name, V_set.max_elt v) :: N_map.bindings (N_map.remove name map_installed))
            ; wish_remove = [] 
            ; wish_upgrade = [] } ]

  let remove name =
    log "remove %s" (Namespace.string_of_name name);
    let t = load_state () in
    let installed = File.Installed.find_map (Path.installed t.home) in

    let v = match N_map.Exceptionless.find name installed with
      | None   -> unknown_package name
      | Some v -> ("=", v.Namespace.deb) in

    let wish_remove, wish_upgrade = [ Namespace.string_of_name name, Some v ], [] in

    resolve t 
      (Path.index_opam_list t.home)
      installed
      [ { Solver.wish_install = List.map vpkg_of_nv (N_map.bindings (N_map.remove name installed))
        ; wish_remove
        ; wish_upgrade }

      ; { Solver.wish_install = []
        ; wish_remove
        ; wish_upgrade } ]
      
  let upgrade () =
    log "upgrade";
    let t = load_state () in
    let l_index = Path.index_opam_list t.home in
    let installed = File.Installed.find_map (Path.installed t.home) in
    resolve t
      l_index
      installed
      [ { Solver.wish_install = []
        ; wish_remove = []
        ; wish_upgrade = 
          List.map
            (fun (name, _) -> 
              match find_from_name name l_index with 
                | None -> assert false (* an already installed package must figure in the index *) 
                | Some v -> vpkg_of_nv (name, V_set.max_elt v))
            (N_map.bindings installed) } ]
    
  (* Upload reads NAME.opam to get the current package version.
     Then it looks for NAME-VERSION.tar.gz in the same directory.
     Then, it sends both NAME.opam and NAME-VERSION.tar.gz to the server *)
  let upload name =
    log "upload %s" name;
    let t = load_state () in

    (* Get the current package version *)
    let opam_filename = name ^ ".opam" in
    let opam_binary = U.read_content opam_filename in
    let opam = File.Opam.parse opam_binary in
    let version = File.Opam.version opam in
    let opam = binary opam_binary in

    (* look for the archive *)
    let archive_filename =
      Namespace.string_of_nv (Namespace.Name name) version ^ ".tar.gz" in
    let archive =
      if Sys.file_exists archive_filename then
        Tar_gz (binary (U.read_content archive_filename))
      else
        Globals.error_and_exit "Cannot find %s" archive_filename in

    (* Upload both files to the server and update the client
       filesystem to reflect the new uploaded packages *)
    let name = Namespace.Name name in
    let local_server = Server.init !Globals.root_path in

    let o_key0 = File.Security_key.find (Path.keys t.home name) in
    let o_key1 = 
      match o_key0 with
        | None -> 
          let o = RemoteServer.newArchive t.server (name, version) opam archive in
          let () = assert (o = Server.newArchive local_server (name, version) opam archive) in
          o
        | Some k -> 
          let b = RemoteServer.updateArchive t.server (name, version) opam archive k in
          let () = assert (b = Server.updateArchive local_server (name, version) opam archive k) in
          if b then Some k else None in

    match o_key1 with
      | Some k1 when o_key0 <> o_key1 -> File.Security_key.add (Path.keys t.home name) k1
      | None -> Globals.msg "The key given to upload was not accepted.\n"
      | _ -> ignore "The server has returned the same key than currently stored.\n"

  type config_request = Dir | Bytelink | Asmlink

  let config is_rec req name =
    log "config %s" (Namespace.string_of_name name);
    let t = load_state () in

    let l_index = Path.index_opam_list t.home in

    let f_is_rec f_true f_false = 
      let installed = File.Installed.find_map (Path.installed t.home) in
      match N_map.Exceptionless.find name installed with
        | None -> unknown_package name
        | Some version -> 

      if is_rec then
        let l_deb = debpkg_of_nv t installed l_index in 
        f_true 
          (Solver.filter_dependencies 
             (List.find
                (fun pkg -> 
                  Namespace.Name pkg.Debian.Packages.name = name 
                  && 
                  pkg.Debian.Packages.version = version.Namespace.deb)
                l_deb)
             l_deb)
      else
        f_false version in

    match find_from_name name l_index, req with
        
      | None, _ -> 
        Globals.msg
          "Package \"%s\" not found. An update of package will be performed.\n"
          (Namespace.string_user_of_name name);
        if confirm "Confirm ?" then
          update_t t
            
      | Some _, Dir -> 
        f_is_rec
          (fun l -> 
            Globals.msg "%s"
              (BatIO.to_string
                 (let i = "-I " in 
                  BatList.print ~first:i ~last:"" ~sep:(" " ^ i) BatString.print)
                 (List.map 
                    (fun pkg -> match Path.ocaml_options_of_library t.home (Namespace.Name pkg.Debian.Packages.name) with I s -> s)
                    l)))
          (fun _ -> 
            Globals.msg "%s"
              (match Path.ocaml_options_of_library t.home name with I s -> s))

      | _ -> 
        let display name version = 
          let l_f, s_cma = 
            match req with
              | Bytelink -> [ File.Descr.link ], ".cma"
              | Asmlink -> [ File.Descr.link ; File.Descr.asmlink ], ".cmxa"
              | Dir -> assert false in
          let descr = File.Descr.find_err (Path.descr t.home (name, version)) in
          
          List.flatten (List.map (fun f -> f descr) l_f), 
          File.Descr.library descr ^ s_cma in
        
        f_is_rec
          (fun l -> 
            let l_opt, l_cma =
              List.split (List.map (fun pkg -> display (Namespace.Name pkg.Debian.Packages.name) { Namespace.deb = pkg.Debian.Packages.version }) l) in
            Globals.msg "%s %s" 
              (String.concat " " (List.flatten l_opt))
              (BatIO.to_string (BatList.print ~first:"" ~last:"" ~sep:" " BatString.print) l_cma))
          (fun version -> 
            let l, s_cma = display name version in
            Globals.msg "%s %s" (String.concat " " l) s_cma)

end










