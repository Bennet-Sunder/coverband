#delegated methods
Coverage.result(clear: true, stop: true) if Coverage.running?
account = Account.first.reload
Coverage.start(methods: true)
account.admin_first_name
result = Coverage.result(clear: true, stop: true)

# AR associations
Coverage.result(clear: true, stop: true) if Coverage.running?
Coverage.start(lines:true, methods: true)
Account.first.data_exports
result = Coverage.result(clear: true, stop: true)