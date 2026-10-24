# alwayswork capability: periderm.runtime (remove)
# Listeners, instances, surfaces and local release state go. The apps' data
# volumes stay unless AW_PURGE=1: they are the only copy of production data.
pd_app_remove_all || return 1
run rm -rf "$(pd_trust_dir)/apps" "$(pd_trust_dir)/activations" "$(pd_trust_dir)/images"
ok "periderm runtime removed"
