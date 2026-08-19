-- 028_prompt_cifras_cupo.sql — dos ajustes que salieron de la primera corrida
-- del informe estructurado (ejecución 22).
--
-- 1. CUPO. tokens_salida = 3897 con max_tokens = 4000: quedó a 103 tokens de
--    cortarse. deepseek-v4-flash razona y los reasoning_tokens cuentan dentro de
--    completion_tokens, así que de esos 3897 la mayoría no era informe (el texto
--    final fueron 1131 caracteres). Si el razonamiento se estira un poco, el JSON
--    llega cortado, no parsea y se gasta un reintento COMPLETO. Subir el tope es
--    más barato que el reintento.
--
-- 2. CIFRAS. El modelo escribió "4.65%", "58.33%" y "$78,300" en la misma
--    respuesta: punto decimal a la inglesa y coma de miles a la inglesa, para un
--    lector colombiano. Pasó la validación porque validar_cifras compara las dos
--    lecturas posibles (migración 026), pero se lee mal.
--
--    Solo se le pide CAMBIAR EL SEPARADOR, nunca redondear. Redondear rompería el
--    informe: validar_cifras compara contra los hallazgos, y un 58,33 escrito
--    como "58,3" no coincide con nada (tres dígitos, entra en la comparación) y
--    se marcaría como cifra inventada, mandando la ejecución al reintento y de
--    ahí al informe seco. La coma decimal en cambio ya está cubierta.
UPDATE prompts SET
    max_tokens = 8000,
    sistema = sistema || '

Cómo escribir las cifras, siempre: separador de miles con punto y decimales con coma, como se escribe en Colombia. $78.300 y no $78,300; 58,33% y no 58.33%. Copiá el número de los hallazgos tal cual y cambiale ÚNICAMENTE el separador: no lo redondeés, no le quites decimales y no lo recalcules.',
    version = version + 1
WHERE servicio_codigo = 'ventas_compras' AND activo;
